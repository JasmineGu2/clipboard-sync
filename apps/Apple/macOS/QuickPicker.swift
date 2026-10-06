import AppKit
import ClipAppCore
import SwiftUI

/// The ⌃⌘V picker: a small floating, searchable list of recent items near the pointer. Up and Down choose,
/// Return copies (and pastes into the app underneath when ClipSync may post keystrokes), Escape closes.
///
/// The panel is non-activating, like Spotlight: it takes the keyboard without bringing ClipSync forward, so the app
/// the user was in stays frontmost and the synthesized ⌘V lands there.
@MainActor
final class QuickPicker: NSObject, NSWindowDelegate {
    private var panel: PickerPanel?
    private var keyMonitor: Any?
    private var model: QuickPickModel?
    private weak var modelHistory: HistoryModel?
    private let status = PickerStatus()
    private var closeTask: Task<Void, Never>?

    var isOpen: Bool { panel?.isVisible == true }

    /// Opens the picker, or closes it when it's already open (pressing ⌃⌘V again).
    func toggle(history: HistoryModel) {
        if isOpen {
            close()
        } else {
            open(history: history)
        }
    }

    func open(history: HistoryModel) {
        let model: QuickPickModel
        if let existing = self.model, modelHistory === history {
            model = existing
        } else {
            model = QuickPickModel(history: history)
            self.model = model
            modelHistory = history
        }
        closeTask?.cancel()
        status.note = nil
        status.canPaste = Self.canPaste
        Task { await model.reset() }

        let panel = self.panel ?? makePanel()
        panel.contentView = NSHostingView(rootView: QuickPickView(model: model, status: status) { [weak self] item in
            self?.choose(item, history: history)
        })
        position(panel)
        panel.makeKeyAndOrderFront(nil)
        startKeyMonitor(model: model, history: history)
    }

    func close() {
        closeTask?.cancel()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        panel?.orderOut(nil)
    }

    // MARK: Choosing

    /// Posting a synthesized keystroke into another app needs the Accessibility grant. This only checks it; it
    /// never shows the system prompt.
    static var canPaste: Bool { CGPreflightPostEventAccess() }

    private func choose(_ item: ClipItem, history: HistoryModel) {
        if Self.canPaste {
            close()
            Task {
                if item.isFile {
                    await history.copyFile(item)
                } else {
                    history.copy(item)
                }
                guard history.lastCopied == item.id else { return }  // the download failed; the menu shows why
                // Give the window underneath a moment to take key again after the panel goes away.
                try? await Task.sleep(for: .milliseconds(60))
                Self.postCommandV()
            }
        } else {
            Task {
                if item.isFile {
                    await history.copyFile(item)
                } else {
                    history.copy(item)
                }
                status.note = history.lastCopied == item.id ? Strings.pickerCopiedNoPaste : history.message?.text
                closeTask?.cancel()
                closeTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(4))
                    guard !Task.isCancelled else { return }
                    self?.close()
                }
            }
        }
    }

    private static func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let v = CGKeyCode(9)  // kVK_ANSI_V
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: keyDown)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }

    // MARK: Keys

    /// A local monitor sees the keys before the search field does, so arrows, Return and Escape drive the list
    /// while every other key types into the field.
    private func startKeyMonitor(model: QuickPickModel, history: HistoryModel) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let code = Int(event.keyCode)
            let windowNumber = event.windowNumber
            // Only Sendable values cross into the main actor: the key code, the window number and the verdict.
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, let panel = self.panel, panel.windowNumber == windowNumber else { return false }
                switch code {
                case 125:  // down
                    model.moveSelection(by: 1)
                case 126:  // up
                    model.moveSelection(by: -1)
                case 36, 76:  // return, keypad enter
                    if let item = model.selectedItem { self.choose(item, history: history) }
                case 53:  // escape
                    self.close()
                default:
                    return false
                }
                return true
            }
            return handled ? nil : event
        }
    }

    // MARK: Panel

    private func makePanel() -> PickerPanel {
        let panel = PickerPanel(
            contentRect: NSRect(x: 0, y: 0, width: QuickPickView.width, height: QuickPickView.height),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered, defer: true)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.delegate = self
        self.panel = panel
        return panel
    }

    /// Just below the pointer, kept on the pointer's screen.
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let size = panel.frame.size
        var origin = NSPoint(x: mouse.x - size.width / 2, y: mouse.y - size.height - 12)
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
            origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        }
        panel.setFrameOrigin(origin)
    }

    /// Clicking anywhere else closes it, like a menu.
    nonisolated func windowDidResignKey(_ notification: Notification) {
        MainActor.assumeIsolated { close() }
    }
}

/// A panel that can take the keyboard although it has no title bar controls.
final class PickerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// What the picker's footer says.
@MainActor
@Observable
final class PickerStatus {
    var note: String?
    var canPaste = false
}

struct QuickPickView: View {
    static let width: CGFloat = 440
    static let height: CGFloat = 380

    @Bindable var model: QuickPickModel
    let status: PickerStatus
    let onChoose: (ClipItem) -> Void
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TextField(Strings.pickerPrompt, text: $model.query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($searchFocused)
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 10)
            Divider()
            list
            Divider()
            Text(status.note ?? (status.canPaste ? Strings.pickerHintPaste : Strings.pickerHintCopy))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .frame(width: Self.width, height: Self.height)
        .onAppear { searchFocused = true }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                        HistoryRow(item: item)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(
                                index == model.selection ? Color.accentColor.opacity(0.22) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 6))
                            .id(item.id)
                            .onTapGesture { onChoose(item) }
                    }
                }
                .padding(6)
            }
            .overlay {
                if model.items.isEmpty {
                    Text(model.query.isEmpty ? Strings.emptyHistory : Strings.noResults)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                }
            }
            .onChange(of: model.selection) { _, _ in
                if let id = model.selectedItem?.id { proxy.scrollTo(id) }
            }
        }
    }
}
