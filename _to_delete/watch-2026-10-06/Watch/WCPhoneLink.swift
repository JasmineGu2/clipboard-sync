import ClipAppCore
import Foundation
import WatchConnectivity

/// `PhoneLink` over WatchConnectivity.
@MainActor
final class WCPhoneLink: NSObject, PhoneLink {
    var onPayload: ((Data) -> Void)?
    private let session = WCSession.default

    func activate() {
        guard session.delegate == nil else { return }
        session.delegate = self
        session.activate()
    }

    func requestCopy(id: String) async -> Bool {
        guard session.activationState == .activated, session.isReachable else { return false }
        let message = [WatchPinnedPayload.copyRequestKey: id]
        return await withCheckedContinuation { continuation in
            session.sendMessage(
                message,
                replyHandler: { reply in
                    continuation.resume(returning: reply[WatchPinnedPayload.copyReplyKey] as? Bool ?? false)
                },
                errorHandler: { _ in continuation.resume(returning: false) })
        }
    }

    private func deliver(_ context: [String: Any]) {
        guard let data = context[WatchPinnedPayload.contextKey] as? Data else { return }
        onPayload?(data)
    }
}

extension WCPhoneLink: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?
    ) {
        // The system keeps the last context it received; pick it up in case it arrived while the app wasn't running.
        let data = session.receivedApplicationContext[WatchPinnedPayload.contextKey] as? Data
        Task { @MainActor in
            if let data { self.onPayload?(data) }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let data = applicationContext[WatchPinnedPayload.contextKey] as? Data
        Task { @MainActor in
            if let data { self.onPayload?(data) }
        }
    }
}
