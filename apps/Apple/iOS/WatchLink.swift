import ClipAppCore
import Foundation
import WatchConnectivity

/// F17: sends the pinned items to the Apple Watch app and answers its "Copy on iPhone" requests.
///
/// The watch gets plain text of pinned items only, never the vault key (docs/threat-model.md). The payload goes
/// out as the WatchConnectivity application context, which keeps only the latest value and is delivered when the
/// watch is next reachable, so a burst of pin changes costs one transfer.
@MainActor
final class WatchLink: NSObject, PinnedItemsMirror {
    static let shared = WatchLink()

    /// Puts a pinned item on this iPhone's clipboard; false when the ID isn't a pinned item. Set by the app.
    var onCopyRequest: ((String) -> Bool)?

    private let session: WCSession? = WCSession.isSupported() ? .default : nil
    /// The newest payload, kept until the session can take it (not activated yet, or no watch app yet).
    private var latest: WatchPinnedPayload?

    func activate() {
        guard let session, session.delegate == nil else { return }
        session.delegate = self
        session.activate()
    }

    func publish(_ payload: WatchPinnedPayload) {
        latest = payload
        send()
    }

    private func send() {
        guard let session, session.activationState == .activated, session.isPaired, session.isWatchAppInstalled,
              let latest, let data = try? latest.encoded()
        else { return }
        // Fails only for an oversized or non-plist context; the payload is capped well under that.
        try? session.updateApplicationContext([WatchPinnedPayload.contextKey: data])
    }

    private func copy(id: String) -> Bool {
        onCopyRequest?(id) ?? false
    }
}

extension WatchLink: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?
    ) {
        Task { @MainActor in self.send() }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    /// The user switched to another watch: activate again so the new one gets the payload.
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    /// The watch app was just installed, or the watch was paired.
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in self.send() }
    }

    nonisolated func session(
        _ session: WCSession, didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        let reply = UncheckedReply(send: replyHandler)
        guard let id = message[WatchPinnedPayload.copyRequestKey] as? String else {
            reply.send([WatchPinnedPayload.copyReplyKey: false])
            return
        }
        Task { @MainActor in
            reply.send([WatchPinnedPayload.copyReplyKey: self.copy(id: id)])
        }
    }
}

/// WatchConnectivity's reply handler isn't marked Sendable, but it's documented as callable from any thread.
struct UncheckedReply: @unchecked Sendable {
    let send: ([String: Any]) -> Void
}
