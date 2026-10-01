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
                .frame(height: 520)
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
        .onAppear { history.setVisible(true) }
        .onDisappear { history.setVisible(false) }
        .alert(Strings.renameTitle, isPresented: isPresented($renaming)) {
            TextField(Strings.renamePlaceholder, text: $renameText)
            Button(Strings.save) {
                if let item = renaming { Task { await history.rename(item, to: renameText) } }
            }
            Button(Strings.cancel, role: .cancel) {}
        }
        .alert(Strings.tagTitle, isPresented: isPresented($tagging)) {
            TextField(Strings.tagPlaceholder, text: $tagText)
            Button(Strings.save) {
                if let item = tagging { Task { await history.addTag(item, tagText) } }
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

struct QuitButton: View {
    var body: some View {
        Button(Strings.menuQuit) {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
