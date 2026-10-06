import ClipSync
import ClipWire
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif os(Windows)
import WinSDK
#endif

// F16: the socket layer behind ClipSync's `PeerDialer` and `PeerListener`, with plain BSD sockets so one
// implementation serves the Mac app, the iPhone (dial only), clipctl on macOS and Linux, and clipctl on Windows
// (Winsock has the same calls). Blocking sockets on their own threads, never on Swift's cooperative pool.
// IPv4 only: devices advertise their Tailscale IPv4 address.

#if os(Windows)
typealias SocketHandle = SOCKET
let invalidSocket = INVALID_SOCKET
#else
typealias SocketHandle = Int32
let invalidSocket: Int32 = -1
#endif

enum Sock {
    static func startup() {
        #if os(Windows)
        _ = winsockStarted
        #endif
    }

    #if os(Windows)
    static let winsockStarted: Bool = {
        var data = WSADATA()
        return WSAStartup(0x0202, &data) == 0
    }()
    #endif

    static func tcp() -> SocketHandle {
        startup()
        #if os(Windows)
        return WinSDK.socket(AF_INET, Int32(SOCK_STREAM), Int32(IPPROTO_TCP.rawValue))
        #elseif canImport(Glibc)
        return Glibc.socket(AF_INET, Int32(SOCK_STREAM.rawValue), Int32(IPPROTO_TCP))
        #else
        return Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        #endif
    }

    static func udp() -> SocketHandle {
        startup()
        #if os(Windows)
        return WinSDK.socket(AF_INET, Int32(SOCK_DGRAM), Int32(IPPROTO_UDP.rawValue))
        #elseif canImport(Glibc)
        return Glibc.socket(AF_INET, Int32(SOCK_DGRAM.rawValue), Int32(IPPROTO_UDP))
        #else
        return Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        #endif
    }

    static func close(_ s: SocketHandle) {
        #if os(Windows)
        _ = closesocket(s)
        #else
        _ = SocketPeer.systemClose(s)
        #endif
    }

    static func lastError() -> String {
        #if os(Windows)
        return "Winsock error \(WSAGetLastError())"
        #else
        return String(cString: strerror(errno))
        #endif
    }

    /// No SIGPIPE when the other side closes first (Darwin per socket; Linux per send).
    static func noSigPipe(_ s: SocketHandle) {
        #if canImport(Darwin)
        var one: Int32 = 1
        _ = setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }

    /// Lets a restarted listener rebind while old connections sit in TIME_WAIT. Not on Windows: there
    /// SO_REUSEADDR also lets a second listener share a port that's in use (the tray app and `clipctl watch`
    /// would split incoming peers), and the default bind already ignores TIME_WAIT.
    static func reuseAddress(_ s: SocketHandle) {
        #if !os(Windows)
        var one: Int32 = 1
        _ = setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }

    static func address(host: String, port: Int) -> sockaddr_in? {
        guard let octets = PeerAddress.ipv4Octets(host), (0...65_535).contains(port) else { return nil }
        var addr = sockaddr_in()
        #if canImport(Darwin)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        #if os(Windows)
        addr.sin_family = ADDRESS_FAMILY(AF_INET)
        #else
        addr.sin_family = sa_family_t(AF_INET)
        #endif
        addr.sin_port = UInt16(port).bigEndian
        let value = UInt32(octets[0]) << 24 | UInt32(octets[1]) << 16 | UInt32(octets[2]) << 8 | UInt32(octets[3])
        #if os(Windows)
        addr.sin_addr.S_un.S_addr = value.bigEndian
        #else
        addr.sin_addr.s_addr = value.bigEndian
        #endif
        return addr
    }

    static func describe(_ addr: sockaddr_in) -> (host: String, port: Int) {
        #if os(Windows)
        let value = UInt32(bigEndian: addr.sin_addr.S_un.S_addr)
        #else
        let value = UInt32(bigEndian: addr.sin_addr.s_addr)
        #endif
        let host = [value >> 24, (value >> 16) & 0xff, (value >> 8) & 0xff, value & 0xff].map(String.init).joined(separator: ".")
        return (host, Int(UInt16(bigEndian: addr.sin_port)))
    }

    static func bind(_ s: SocketHandle, _ addr: sockaddr_in) -> Bool {
        var addr = addr
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                #if os(Windows)
                WinSDK.bind(s, $0, Int32(MemoryLayout<sockaddr_in>.size)) == 0
                #else
                SocketPeer.systemBind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                #endif
            }
        }
    }

    static func connect(_ s: SocketHandle, _ addr: sockaddr_in) -> Bool {
        var addr = addr
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                #if os(Windows)
                WinSDK.connect(s, $0, Int32(MemoryLayout<sockaddr_in>.size)) == 0
                #else
                SocketPeer.systemConnect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                #endif
            }
        }
    }

    static func localAddress(_ s: SocketHandle) -> sockaddr_in? {
        var addr = sockaddr_in()
        #if os(Windows)
        var length = Int32(MemoryLayout<sockaddr_in>.size)
        #else
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        #endif
        let ok = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &length) == 0 }
        }
        return ok ? addr : nil
    }

    /// Connects with a timeout: non-blocking connect, then wait for writability.
    static func connect(_ s: SocketHandle, _ addr: sockaddr_in, timeoutMillis: Int32) -> Bool {
        setBlocking(s, false)
        defer { setBlocking(s, true) }
        if connect(s, addr) { return true }
        #if os(Windows)
        guard WSAGetLastError() == WSAEWOULDBLOCK else { return false }
        var fd = WSAPOLLFD(fd: s, events: Int16(POLLWRNORM), revents: 0)
        guard WSAPoll(&fd, 1, timeoutMillis) == 1 else { return false }
        #else
        guard errno == EINPROGRESS else { return false }
        var fd = pollfd(fd: s, events: Int16(POLLOUT), revents: 0)
        guard poll(&fd, 1, timeoutMillis) == 1 else { return false }
        #endif
        var error: Int32 = 0
        #if os(Windows)
        var length = Int32(MemoryLayout<Int32>.size)
        let ok = withUnsafeMutablePointer(to: &error) {
            $0.withMemoryRebound(to: CChar.self, capacity: 4) { getsockopt(s, SOL_SOCKET, SO_ERROR, $0, &length) }
        }
        #else
        var length = socklen_t(MemoryLayout<Int32>.size)
        let ok = getsockopt(s, SOL_SOCKET, SO_ERROR, &error, &length)
        #endif
        return ok == 0 && error == 0
    }

    static func setBlocking(_ s: SocketHandle, _ blocking: Bool) {
        #if os(Windows)
        var mode: u_long = blocking ? 0 : 1
        _ = ioctlsocket(s, FIONBIO, &mode)
        #else
        let flags = fcntl(s, F_GETFL, 0)
        _ = fcntl(s, F_SETFL, blocking ? flags & ~O_NONBLOCK : flags | O_NONBLOCK)
        #endif
    }

    /// Waits until the socket is readable (or writable) or `deadline` passes. False on timeout or error.
    static func wait(_ s: SocketHandle, readable: Bool, until deadline: Date) -> Bool {
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return false }
            let millis = Int32(min(remaining * 1000, 1000).rounded(.up))
            #if os(Windows)
            var fd = WSAPOLLFD(fd: s, events: Int16(readable ? POLLRDNORM : POLLWRNORM), revents: 0)
            let n = WSAPoll(&fd, 1, millis)
            #else
            var fd = pollfd(fd: s, events: Int16(readable ? POLLIN : POLLOUT), revents: 0)
            let n = poll(&fd, 1, millis)
            #endif
            if n > 0 { return true }
            if n < 0, !isTransient() { return false }
        }
    }

    /// Writes all of `data`, 64 KiB per call, before `deadline`. Transient "try again" errors (macOS gives ENOBUFS
    /// for large sends on loopback) are retried until the deadline.
    static func writeAll(_ s: SocketHandle, _ data: Data, until deadline: Date) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            var sent = 0
            while sent < raw.count {
                guard wait(s, readable: false, until: deadline) else { return false }
                let piece = min(raw.count - sent, 64 * 1024)
                #if os(Windows)
                let n = Int(WinSDK.send(s, base.advanced(by: sent).assumingMemoryBound(to: CChar.self), Int32(piece), 0))
                #elseif canImport(Glibc)
                let n = Glibc.send(s, base.advanced(by: sent), piece, Int32(MSG_NOSIGNAL))
                #else
                let n = Darwin.send(s, base.advanced(by: sent), piece, 0)
                #endif
                if n > 0 {
                    sent += n
                    continue
                }
                guard n < 0, isTransient() else { return false }
                Thread.sleep(forTimeInterval: 0.005)
            }
            return true
        }
    }

    static func isTransient() -> Bool {
        #if os(Windows)
        let code = WSAGetLastError()
        return code == WSAEWOULDBLOCK || code == WSAENOBUFS || code == WSAEINTR
        #else
        return errno == ENOBUFS || errno == EINTR || errno == EAGAIN
        #endif
    }

    /// Reads exactly `count` bytes before `deadline`, growing the buffer as bytes arrive (a peer that announces
    /// 8 MiB and sends nothing costs nothing). nil if the connection ends, errors or the deadline passes.
    static func readExactly(_ s: SocketHandle, _ count: Int, until deadline: Date) -> Data? {
        var out = Data()
        var buffer = [UInt8](repeating: 0, count: min(count, 64 * 1024))
        while out.count < count {
            guard wait(s, readable: true, until: deadline) else { return nil }
            let want = min(count - out.count, buffer.count)
            let n = buffer.withUnsafeMutableBytes { raw -> Int in
                #if os(Windows)
                Int(WinSDK.recv(s, raw.baseAddress!.assumingMemoryBound(to: CChar.self), Int32(want), 0))
                #elseif canImport(Glibc)
                Glibc.recv(s, raw.baseAddress!, want, 0)
                #else
                Darwin.recv(s, raw.baseAddress!, want, 0)
                #endif
            }
            if n > 0 {
                out.append(contentsOf: buffer[0..<n])
            } else if n < 0, isTransient() {
                continue
            } else {
                return nil
            }
        }
        return out
    }

    /// Reads one length-prefixed frame before `deadline`, refusing anything over `PeerLimits.maxFrameBytes`.
    static func readFrame(_ s: SocketHandle, until deadline: Date) -> Data? {
        guard let header = readExactly(s, 4, until: deadline),
              let length = PeerFraming.bodyLength(header: Array(header))
        else { return nil }
        return length == 0 ? Data() : readExactly(s, length, until: deadline)
    }
}

/// Namespaced wrappers for the POSIX calls whose Swift names collide with our own.
enum SocketPeer {
    #if !os(Windows)
    static func systemClose(_ s: Int32) -> Int32 {
        #if canImport(Glibc)
        Glibc.close(s)
        #else
        Darwin.close(s)
        #endif
    }

    static func systemBind(_ s: Int32, _ addr: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
        #if canImport(Glibc)
        Glibc.bind(s, addr, length)
        #else
        Darwin.bind(s, addr, length)
        #endif
    }

    static func systemConnect(_ s: Int32, _ addr: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
        #if canImport(Glibc)
        Glibc.connect(s, addr, length)
        #else
        Darwin.connect(s, addr, length)
        #endif
    }

    static func systemAccept(_ s: Int32) -> Int32 {
        #if canImport(Glibc)
        Glibc.accept(s, nil, nil)
        #else
        Darwin.accept(s, nil, nil)
        #endif
    }
    #endif
}

/// Dials another device's listener with a fresh TCP connection per exchange.
public struct SocketPeerDialer: PeerDialer {
    public init() {}

    public func exchange(host: String, port: Int, request: Data, timeout: Duration) async throws -> Data {
        guard request.count <= PeerLimits.maxFrameBytes else { throw PeerTransportError.badFrame }
        guard let address = Sock.address(host: host, port: port) else {
            throw PeerTransportError.unreachable("not an IPv4 address: \(host)")
        }
        let seconds = max(1, Int(timeout.components.seconds))
        return try await withCheckedThrowingContinuation { continuation in
            // A plain thread, not the cooperative pool: these calls block.
            Thread.detachNewThread {
                continuation.resume(with: Result { try Self.blockingExchange(address, request, seconds: seconds) })
            }
        }
    }

    static func blockingExchange(_ address: sockaddr_in, _ request: Data, seconds: Int) throws -> Data {
        let s = Sock.tcp()
        guard s != invalidSocket else { throw PeerTransportError.unreachable(Sock.lastError()) }
        defer { Sock.close(s) }
        Sock.noSigPipe(s)
        guard Sock.connect(s, address, timeoutMillis: Int32(seconds * 1000)) else {
            let (host, port) = Sock.describe(address)
            throw PeerTransportError.unreachable("\(host):\(port)")
        }
        // One deadline for the whole exchange, so a peer that trickles bytes can't stall the pass.
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        guard Sock.writeAll(s, PeerFraming.frame(request), until: deadline) else { throw PeerTransportError.timeout }
        guard let answer = Sock.readFrame(s, until: deadline) else { throw PeerTransportError.badFrame }
        return answer
    }
}

/// Listens on one IPv4 address. Each connection is served on its own thread, at most `maxConnections` at once
/// (more wait in the accept backlog); each must send its frame within `ioTimeoutSeconds`.
public final class SocketPeerListener: PeerListener, @unchecked Sendable {
    public static let maxConnections = 8
    public static let ioTimeoutSeconds = 10
    /// How long one connection may take to send its request (and then get its answer).
    let ioTimeout: TimeInterval

    private let lock = NSLock()
    private var socket: SocketHandle = invalidSocket
    private var stopped = false
    private var started = false
    private let slots = DispatchSemaphore(value: SocketPeerListener.maxConnections)
    public private(set) var boundAddress: String

    /// Binds now (so a taken port fails here); `port` 0 picks a free one.
    public init(host: String, port: Int, ioTimeout: TimeInterval = TimeInterval(SocketPeerListener.ioTimeoutSeconds)) throws {
        self.ioTimeout = ioTimeout
        guard let address = Sock.address(host: host, port: port) else {
            throw PeerTransportError.bindFailed("not an IPv4 address: \(host)")
        }
        let s = Sock.tcp()
        guard s != invalidSocket else { throw PeerTransportError.bindFailed(Sock.lastError()) }
        Sock.reuseAddress(s)
        guard Sock.bind(s, address) else {
            let message = Sock.lastError()
            Sock.close(s)
            throw PeerTransportError.bindFailed("\(host):\(port): \(message)")
        }
        #if os(Windows)
        let listening = WinSDK.listen(s, 16) == 0
        #elseif canImport(Glibc)
        let listening = Glibc.listen(s, 16) == 0
        #else
        let listening = Darwin.listen(s, 16) == 0
        #endif
        guard listening, let bound = Sock.localAddress(s) else {
            let message = Sock.lastError()
            Sock.close(s)
            throw PeerTransportError.bindFailed(message)
        }
        let described = Sock.describe(bound)
        socket = s
        boundAddress = PeerAddress.format(host: described.host, port: described.port)
    }

    public func start(handler: @escaping @Sendable (Data) async -> Data) throws {
        let s = lock.withLock { socket }
        guard s != invalidSocket else { throw PeerTransportError.bindFailed("stopped") }
        Thread.detachNewThread { [self] in acceptLoop(s, handler) }
    }

    /// Stops accepting. The accept thread notices within a quarter second and closes the socket itself, so the fd
    /// can't be reused under it. A listener that was never started closes it here.
    public func stop() {
        let (s, wasStarted) = lock.withLock { () -> (SocketHandle, Bool) in
            stopped = true
            let s = socket
            socket = invalidSocket
            return (s, started)
        }
        if s != invalidSocket, !wasStarted { Sock.close(s) }
    }

    deinit { stop() }

    private func acceptLoop(_ listening: SocketHandle, _ handler: @escaping @Sendable (Data) async -> Data) {
        lock.withLock { started = true }
        defer { Sock.close(listening) }
        while !lock.withLock({ stopped }) {
            guard Sock.wait(listening, readable: true, until: Date().addingTimeInterval(0.25)) else { continue }
            if lock.withLock({ stopped }) { return }
            #if os(Windows)
            let client = WinSDK.accept(listening, nil, nil)
            #else
            let client = SocketPeer.systemAccept(listening)
            #endif
            guard client != invalidSocket else {
                Thread.sleep(forTimeInterval: 0.05)  // EMFILE and the like: don't spin
                continue
            }
            // At most `maxConnections` at once; a full house closes the newcomer rather than queueing it forever.
            guard slots.wait(timeout: .now() + 1) == .success else {
                Sock.close(client)
                continue
            }
            let ioTimeout = self.ioTimeout
            Thread.detachNewThread { [slots] in
                defer {
                    Sock.close(client)
                    slots.signal()
                }
                Sock.noSigPipe(client)
                // One deadline per connection: reading the request, answering, and writing it.
                let deadline = Date().addingTimeInterval(ioTimeout)
                guard let request = Sock.readFrame(client, until: deadline) else { return }
                let done = DispatchSemaphore(value: 0)
                let box = ResponseBox()
                Task {
                    box.value = await handler(request)
                    done.signal()
                }
                done.wait()
                _ = Sock.writeAll(client, PeerFraming.frame(box.value), until: deadline.addingTimeInterval(5))
            }
        }
    }

    private final class ResponseBox: @unchecked Sendable {
        var value = Data()
    }
}

/// This device's Tailscale IPv4 address, found without asking Tailscale: a UDP socket "connected" to 100.100.100.100
/// (Tailscale's own resolver, routed through the tailnet interface) reports the local address the OS would use. No
/// packet is sent. nil when that isn't a tailnet address (Tailscale off).
public enum TailnetAddress {
    public static func detect() -> String? {
        guard let target = Sock.address(host: "100.100.100.100", port: 53) else { return nil }
        let s = Sock.udp()
        guard s != invalidSocket else { return nil }
        defer { Sock.close(s) }
        guard Sock.connect(s, target), let local = Sock.localAddress(s) else { return nil }
        let host = Sock.describe(local).host
        return PeerAddress.isTailnet(host) ? host : nil
    }
}
