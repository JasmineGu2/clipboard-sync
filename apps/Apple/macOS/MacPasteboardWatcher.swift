import AppKit
import ClipAppCore

/// F1 on the Mac. macOS has no clipboard-change notification, so this reads NSPasteboard.changeCount
/// (a cheap integer read) every 0.5 s with generous timer tolerance, and stops the timer entirely while the
/// screen is asleep or locked, the Mac is asleep, or the user session is switched out (N4: "Low" energy).
/// The capture decision itself is ClipboardPoller + CaptureFilter in ClipAppCore, tested on every platform:
/// text, images and copied files (F1, F11, F12), with the same concealed and pause rules for all of them.
@MainActor
final class MacPasteboardWatcher {
    static let interval: TimeInterval = 0.5

    private enum Suspension: Hashable, Sendable {
        case screenAsleep, systemAsleep, locked, sessionInactive
    }

    private let poller: ClipboardPoller
    private let onCapture: (Clip) -> Void
    private var timer: Timer?
    private var suspensions: Set<Suspension> = []
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var started = false

    var isPaused: Bool {
        get { poller.isPaused }
        set { poller.isPaused = newValue }
    }

    init(reader: any PasteboardReader, isPaused: Bool, onCapture: @escaping (Clip) -> Void) {
        self.poller = ClipboardPoller(reader: reader, isPaused: isPaused)
        self.onCapture = onCapture
    }

    func start() {
        guard !started else { return }
        started = true
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.screensDidSleepNotification, suspending: true, .screenAsleep)
        observe(workspace, NSWorkspace.screensDidWakeNotification, suspending: false, .screenAsleep)
        observe(workspace, NSWorkspace.willSleepNotification, suspending: true, .systemAsleep)
        observe(workspace, NSWorkspace.didWakeNotification, suspending: false, .systemAsleep)
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification, suspending: true, .sessionInactive)
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification, suspending: false, .sessionInactive)
        // Screen lock has no public NSWorkspace notification; these distributed ones are what loginwindow posts.
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsLocked"), suspending: true, .locked)
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked"), suspending: false, .locked)
        updateTimer()
    }

    func stop() {
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
        started = false
        timer?.invalidate()
        timer = nil
    }

    /// The observer block is `@Sendable`, so it captures only Sendable values: the reason and the direction, not a
    /// closure. It's delivered on the main queue, so it can step into the main actor.
    private func observe(_ center: NotificationCenter, _ name: Notification.Name, suspending: Bool, _ reason: Suspension) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if suspending {
                    self.suspend(reason)
                } else {
                    self.resume(reason)
                }
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
        if let clip = poller.pollClip() {
            onCapture(clip)
        }
    }
}
