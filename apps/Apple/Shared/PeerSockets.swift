import ClipAppCore
import ClipPeerSocket
import ClipSync

/// F16: the sockets for direct device-to-device sync while the relay is unreachable (ClipPeerSocket).
enum PeerSockets {
    /// The port the Mac listens on, so other devices find it at the same address across launches. If it's taken,
    /// any free port (re-advertised on the next relay sync).
    static let macPort = 8790

    /// Mac: listens on its Tailscale address and dials. No listener when Tailscale is off at launch.
    static let mac = PeerSupport(dialer: SocketPeerDialer(), makeListener: {
        guard let host = TailnetAddress.detect() else { return nil }
        return (try? SocketPeerListener(host: host, port: macPort)) ?? (try? SocketPeerListener(host: host, port: 0))
    })

    /// iPhone: dials only. iOS suspends apps in the background, so a listener there would rarely answer.
    static let dialOnly = PeerSupport(dialer: SocketPeerDialer())
}
