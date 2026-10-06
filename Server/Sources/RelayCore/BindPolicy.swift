import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// N10: the relay is reachable only inside the tailnet. It has no TLS and relies on Tailscale's tunnel, so it
/// refuses to start on an address outside loopback and the tailnet unless the operator says so explicitly
/// (`--allow-non-tailnet`), for example inside a container whose published port is pinned to the Tailscale IP.
public enum BindPolicy {
    public enum Kind: Equatable, Sendable {
        /// 127.0.0.0/8, ::1, or `localhost`.
        case loopback
        /// Tailscale's ranges: 100.64.0.0/10 (CGNAT, IPv4) and fd7a:115c:a1e0::/48 (IPv6).
        case tailnet
        /// 0.0.0.0 or ::: every interface, the public one included.
        case everyInterface
        /// Any other address, or a host name the relay can't check before binding.
        case other
    }

    public enum Decision: Equatable, Sendable {
        case allow
        /// Allowed, with a warning to log.
        case warn(String)
        /// Refused: print the message and exit.
        case refuse(String)
    }

    /// Classifies `host` as given to `--host`. Only IP literals and `localhost` are recognized; a host name can
    /// resolve to anything, so it counts as `.other`.
    public static func classify(_ host: String) -> Kind {
        var text = host.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("["), text.hasSuffix("]") { text = String(text.dropFirst().dropLast()) }
        if text.lowercased() == "localhost" { return .loopback }
        if let v4 = ipv4(text) { return classify(v4: v4) }
        if let v6 = ipv6(text) {
            if v6.allSatisfy({ $0 == 0 }) { return .everyInterface }
            if v6[0..<15].allSatisfy({ $0 == 0 }) && v6[15] == 1 { return .loopback }
            // IPv4-mapped (::ffff:a.b.c.d): judge the IPv4 address.
            if v6[0..<10].allSatisfy({ $0 == 0 }) && v6[10] == 0xff && v6[11] == 0xff {
                return classify(v4: Array(v6[12..<16]))
            }
            if v6[0..<6] == [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0] { return .tailnet }
            return .other
        }
        return .other
    }

    /// What to do about binding `host`. `allowNonTailnet` is the operator's explicit opt-in.
    public static func decide(host: String, allowNonTailnet: Bool) -> Decision {
        switch classify(host) {
        case .loopback, .tailnet:
            return .allow
        case .everyInterface where allowNonTailnet:
            return .warn("Listening on every interface. Outside a container whose published port is pinned to the "
                + "Tailscale IP, bind the Tailscale IP instead.")
        case .other where allowNonTailnet:
            return .warn("\(host) is not loopback or a Tailscale address; anyone who can reach it can reach the relay.")
        case .everyInterface, .other:
            return .refuse("""
                refusing to bind \(host): it is not loopback (127.0.0.0/8, ::1) or a Tailscale address \
                (100.64.0.0/10, fd7a:115c:a1e0::/48), and the relay has no TLS (N10). Bind the Tailscale IP \
                (`tailscale ip -4`), or pass --allow-non-tailnet (CLIP_RELAY_ALLOW_NON_TAILNET=1) if something else \
                keeps the port off the internet, such as `docker run -p <tailscale ip>:8787:8787`.
                """)
        }
    }

    private static func classify(v4: [UInt8]) -> Kind {
        if v4 == [0, 0, 0, 0] { return .everyInterface }
        if v4[0] == 127 { return .loopback }
        if v4[0] == 100 && (v4[1] & 0xC0) == 64 { return .tailnet }
        return .other
    }

    private static func ipv4(_ text: String) -> [UInt8]? {
        var address = in_addr()
        guard inet_pton(AF_INET, text, &address) == 1 else { return nil }
        return withUnsafeBytes(of: &address) { Array($0) }
    }

    private static func ipv6(_ text: String) -> [UInt8]? {
        var address = in6_addr()
        guard inet_pton(AF_INET6, text, &address) == 1 else { return nil }
        return withUnsafeBytes(of: &address) { Array($0) }
    }
}
