import AppKit
import ClipAppCore

/// F1 on the Mac. macOS has no clipboard-change notification, so this reads NSPasteboard.changeCount
/// (a cheap integer read) every 0.5 s with generous timer tolerance, and stops the timer entirely while the
/// screen is asleep or locked, the Mac is asleep, or the user session is switched out (N4: "Low" energy).
/// The capture decision itself is ClipboardPoller + CaptureFilter in ClipAppCore, tested on every platform.
@MainActor
final class MacPasteboardWatcher {
    static let interval: TimeInterval = 0.5

    private enum Suspension: Hashable {
        case screenAsleep, systemAsleep, locked, sessionInactive
    }

    private let poller: ClipboardPoller
    private let onCapture: (String) -> Void
    private var timer: Timer?
    private var suspensions: Set<Suspension> = []
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var started = false

    var isPaused: Bool {
        get { poller.isPaused }
        set { poller.isPaused = newValue }
    }

    init(reader: any PasteboardReader, isPaused: Bool, onCapture: @escaping (String) -> Void) {
        self.poller = ClipboardPoller(reader: reader, isPaused: isPaused)
        self.onCapture = onCapture
    }

    func start() {
        guard !started else { return }
        started = true
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.suspend(.screenAsleep) }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.resume(.screenAsleep) }
        observe(workspace, NSWorkspace.willSleepNotification) { $0.suspend(.systemAsleep) }
        observe(workspace, NSWorkspace.didWakeNotification) { $0.resume(.systemAsleep) }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.suspend(.sessionInactive) }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.resume(.sessionInactive) }
        // Screen lock has no public NSWorkspace notification; these distributed ones are what loginwindow posts.
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.suspend(.locked) }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.resume(.locked) }
        updateTimer()
    }

    func stop() {
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
        started = false
        timer?.invalidate()
        timer = nil
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ handler: @escaping @MainActor (MacPasteboardWatcher) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self)
            }
        }
        observers.append((center, token))
    }

    private func suspend(_ reason: Suspension) {
        suspensions.insert(reason)
        updateTimer()
    }

    private func resume(_ reason: Suspension) {
        suspensions.remove(reason)
        updateTimer()
    }

    private func updateTimer() {
        let shouldRun = started && suspensions.isEmpty
        if shouldRun, timer == nil {
            let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            // Lets the OS coalesce wakeups with other timers.
            timer.tolerance = Self.interval / 2
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            tick()  // Catch anything copied while suspended (the poller compares changeCount).
        } else if !shouldRun, let timer {
            timer.invalidate()
            self.timer = nil
        }
    }

    private func tick() {
        if let text = poller.poll() {
            onCapture(text)
        }
    }
}
