import AppKit
import ClipAppCore
import SwiftUI

/// The menu bar window: onboarding until set up, then the history.
struct MenuContentView: View {
    let controller: MacAppController
    @State private var showingPair = false

    var body: some View {
        Group {
            switch controller.app.state {
            case .needsSetup, .working:
                VStack(alignment: .leading, spacing: 0) {
                    Text(Strings.onboardingTitle)
                        .font(.headline)
                        .padding([.top, .horizontal])
                    OnboardingView(app: controller.app) {
                        controller.startWatcherIfReady()
                    }
                    Divider()
                    QuitButton()
                        .padding(8)
                }
                .frame(height: 640)
            case .ready:
                if showingPair {
                    PairView(app: controller.app) { showingPair = false }
                } else if let history = controller.app.history {
                    MacHistoryView(history: history, controller: controller, showingPair: $showingPair)
                }
            case .failed(let message):
                VStack(spacing: 12) {
                    Text(message.text)
                    QuitButton()
                }
                .padding()
            }
        }
        .frame(width: 380)
    }
}

struct MacHistoryView: View {
    @Bindable var history: HistoryModel
    let controller: MacAppController
    @Binding var showingPair: Bool

    @State private var renaming: ClipItem?
    @State private var renameText = ""
    @State private var tagging: ClipItem?
    @State private var tagText = ""

    var body: some View {
        VStack(spacing: 0) {
            TextField(Strings.searchPrompt, text: $history.searchText)
                .textFieldStyle(.roundedBorder)
                .padding(8)

            List {
                if !history.pinned.isEmpty {
                    Section(Strings.sectionPinned) {
                        ForEach(history.pinned) { row($0) }
                    }
                }
                Section(Strings.sectionRecent) {
                    ForEach(history.recent) { row($0) }
                    if history.canLoadMore {
                        Button(Strings.loadMore) {
                            Task { await history.loadMore() }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .overlay {
                if history.isEmpty {
                    Text(history.searchText.isEmpty ? Strings.emptyHistory : Strings.noResults)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                }
            }
            .frame(height: 420)

            Divider()
            footer
                .padding(8)
        }
        // A MenuBarExtra window is created once and then only hidden, so onAppear/onDisappear don't track
        // whether the menu is open. The window is key exactly while it's showing; follow that instead (N4).
        .background(WindowKeyObserver { history.setVisible($0) })
        .onDisappear { history.setVisible(false) }
        // `presenting:` hands the item to the buttons. Reading `renaming` there instead would see nil:
        // the alert clears the binding before the button action runs.
        .alert(Strings.renameTitle, isPresented: isPresented($renaming), presenting: renaming) { item in
            TextField(Strings.renamePlaceholder, text: $renameText)
            Button(Strings.save) {
                let title = renameText
                Task { await history.rename(item, to: title) }
            }
            Button(Strings.cancel, role: .cancel) {}
        }
        .alert(Strings.tagTitle, isPresented: isPresented($tagging), presenting: tagging) { item in
            TextField(Strings.tagPlaceholder, text: $tagText)
            Button(Strings.save) {
                let tag = tagText
                Task { await history.addTag(item, tag) }
            }
            Button(Strings.cancel, role: .cancel) {}
        }
        .alert(Strings.appName, isPresented: messageShown, presenting: history.message) { _ in
            Button(Strings.ok) {}
        } message: { message in
            Text(message.text)
        }
    }

    private var footer: some View {
        HStack {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(controller.app.capturePaused ? Strings.capturePaused : history.syncStatus.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Menu {
                Button(controller.app.capturePaused ? Strings.menuResumeCapture : Strings.menuPauseCapture) {
                    controller.setCapturePaused(!controller.app.capturePaused)
                }
                Button(Strings.menuPairDevice) { showingPair = true }
                Divider()
                QuitButton()
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private var statusColor: Color {
        if controller.app.capturePaused { return .yellow }
        switch history.syncStatus {
        case .synced: return .green
        case .syncing: return .blue
        case .offline: return .red
        }
    }

    private func row(_ item: ClipItem) -> some View {
        Button {
            history.copy(item)
        } label: {
            HistoryRow(item: item, justCopied: history.lastCopied == item.id)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(Strings.actionCopy) { history.copy(item) }
            Button(item.isPinned ? Strings.actionUnpin : Strings.actionPin) {
                Task { await history.togglePin(item) }
            }
            Button(Strings.actionRename) {
                renameText = item.title ?? ""
                renaming = item
            }
            Button(Strings.actionAddTag) {
                tagText = ""
                tagging = item
            }
            ForEach(item.tags, id: \.self) { tag in
                Button(Strings.format(Strings.actionRemoveTag, ["tag": tag])) {
                    Task { await history.removeTag(item, tag) }
                }
            }
            Divider()
            Button(Strings.actionDelete, role: .destructive) {
                Task { await history.delete(item) }
            }
        }
    }

    private var messageShown: Binding<Bool> {
        Binding(get: { history.message != nil }, set: { if !$0 { history.message = nil } })
    }

    private func isPresented(_ item: Binding<ClipItem?>) -> Binding<Bool> {
        Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
    }
}

/// Reports whether the hosting window is the key window, from NSWindow's key notifications.
/// The menu bar window becomes key when it opens and resigns key when it closes.
struct WindowKeyObserver: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> KeyObservingView {
        let view = KeyObservingView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: KeyObservingView, context: Context) {
        view.onChange = onChange
    }

    final class KeyObservingView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers = []
            guard let window else {
                onChange?(false)
                return
            }
            let names: [(Notification.Name, Bool)] = [
                (NSWindow.didBecomeKeyNotification, true),
                (NSWindow.didResignKeyNotification, false),
            ]
            for (name, isKey) in names {
                let observer = NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.onChange?(isKey) }
                }
                observers.append(observer)
            }
            onChange?(window.isKeyWindow)
        }
    }
}

struct QuitButton: View {
    var body: some View {
        Button(Strings.menuQuit) {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
