import ClipWire
import Foundation

// F16: the socket layer for direct device-to-device sync, behind protocols so ClipSync stays free of platform APIs.
// ClipPeerSocket implements both with BSD sockets (macOS, iOS, Linux, Windows); tests use `InMemoryPeerNetwork`.
// Wire format: ClipWire (PeerRequestFrame / PeerResponseFrame), one length-prefixed frame each way per connection.

/// Dials another device: sends one request frame and returns its response frame.
public protocol PeerDialer: Sendable {
    /// Connects to `host:port`, writes `request` as one frame, reads one frame back, closes.
    /// Throws `PeerTransportError` (unreachable, timeout, a frame over `PeerLimits.maxFrameBytes`).
    func exchange(host: String, port: Int, request: Data, timeout: Duration) async throws -> Data
}

/// Accepts connections from other devices. For each one: read one frame, pass it to the handler, write what the
/// handler returns as one frame, close.
public protocol PeerListener: AnyObject, Sendable {
    /// Starts accepting. The handler is the engine's `handlePeerRequest`.
    func start(handler: @escaping @Sendable (Data) async -> Data) throws
    func stop()
    /// "<IPv4>:<port>" actually bound (the port is known only after binding when 0 was asked for).
    var boundAddress: String { get }
}

public enum PeerTransportError: Error, Equatable, Sendable, CustomStringConvertible {
    /// Connection refused, no route, or the address doesn't parse.
    case unreachable(String)
    case timeout
    /// The other side sent a length prefix over `PeerLimits.maxFrameBytes`, or closed mid-frame.
    case badFrame
    /// Binding the listener failed (address not on this machine, port taken).
    case bindFailed(String)

    public var description: String {
        switch self {
        case .unreachable(let message): "unreachable: \(message)"
        case .timeout: "timed out"
        case .badFrame: "malformed frame"
        case .bindFailed(let message): "can't listen: \(message)"
        }
    }
}

/// "<IPv4>:<port>" addresses, as devices advertise them in their (sealed) device records.
public enum PeerAddress {
    /// Parses "a.b.c.d:port". Only IPv4 literals: no DNS lookups for an address another device chose.
    public static func parse(_ address: String) -> (host: String, port: Int)? {
        let parts = address.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let port = Int(parts[1]), (1...65_535).contains(port),
              let octets = ipv4Octets(String(parts[0]))
        else { return nil }
        return (octets.map(String.init).joined(separator: "."), port)
    }

    public static func format(host: String, port: Int) -> String { "\(host):\(port)" }

    /// The four octets of a dotted-quad IPv4 literal, or nil.
    public static func ipv4Octets(_ host: String) -> [UInt8]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [UInt8] = []
        for part in parts {
            guard (1...3).contains(part.count), part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber),
                  let value = UInt8(part)
            else { return nil }
            octets.append(value)
        }
        return octets
    }

    /// Tailscale gives every device an address in 100.64.0.0/10 (the CGNAT range).
    public static func isTailnet(_ host: String) -> Bool {
        guard let octets = ipv4Octets(host) else { return false }
        return octets[0] == 100 && (64...127).contains(octets[1])
    }

    public static func isLoopback(_ host: String) -> Bool {
        ipv4Octets(host)?.first == 127
    }
}

/// Length-prefixed frames: 4 bytes big-endian length, then the body.
public enum PeerFraming {
    public static func frame(_ body: Data) -> Data {
        var out = Data(capacity: body.count + 4)
        let length = UInt32(body.count)
        out.append(contentsOf: [UInt8(length >> 24), UInt8((length >> 16) & 0xff), UInt8((length >> 8) & 0xff), UInt8(length & 0xff)])
        out.append(body)
        return out
    }

    /// The body length announced by a 4-byte header, or nil when it's over `PeerLimits.maxFrameBytes`.
    public static func bodyLength(header: [UInt8]) -> Int? {
        guard header.count == 4 else { return nil }
        let length = Int(header[0]) << 24 | Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
        return length <= PeerLimits.maxFrameBytes ? length : nil
    }
}

/// Peer connections without sockets, for tests: listeners register a handler under an address, dialers call it.
/// `setReachable(_:_:)` cuts one address off, like a device going to sleep.
public final class InMemoryPeerNetwork: @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [String: @Sendable (Data) async -> Data] = [:]
    private var unreachable: Set<String> = []
    private var nextPort = 9000
    /// Requests that reached a handler, for tests.
    public private(set) var deliveredCount = 0

    public init() {}

    public func setReachable(_ address: String, _ reachable: Bool) {
        lock.withLock { if reachable { unreachable.remove(address) } else { unreachable.insert(address) } }
    }

    /// A listener on a fresh loopback-style address.
    public func makeListener(host: String = "100.64.0.1") -> PeerListener {
        let port = lock.withLock { () -> Int in
            nextPort += 1
            return nextPort
        }
        return Listener(network: self, address: PeerAddress.format(host: host, port: port))
    }

    public var dialer: any PeerDialer { Dialer(network: self) }

    fileprivate func register(_ address: String, _ handler: (@Sendable (Data) async -> Data)?) {
        lock.withLock { handlers[address] = handler }
    }

    fileprivate func handler(for address: String) -> (@Sendable (Data) async -> Data)? {
        lock.withLock {
            guard !unreachable.contains(address), let handler = handlers[address] else { return nil }
            deliveredCount += 1
            return handler
        }
    }

    final class Listener: PeerListener, @unchecked Sendable {
        let network: InMemoryPeerNetwork
        let boundAddress: String

        init(network: InMemoryPeerNetwork, address: String) {
            self.network = network
            self.boundAddress = address
        }

        func start(handler: @escaping @Sendable (Data) async -> Data) throws { network.register(boundAddress, handler) }
        func stop() { network.register(boundAddress, nil) }
    }

    struct Dialer: PeerDialer {
        let network: InMemoryPeerNetwork

        func exchange(host: String, port: Int, request: Data, timeout: Duration) async throws -> Data {
            let address = PeerAddress.format(host: host, port: port)
            guard let handler = network.handler(for: address) else { throw PeerTransportError.unreachable(address) }
            guard request.count <= PeerLimits.maxFrameBytes else { throw PeerTransportError.badFrame }
            return await handler(request)
        }
    }
}
