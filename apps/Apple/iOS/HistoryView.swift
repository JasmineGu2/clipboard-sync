import ClipAppCore
import SwiftUI

struct HistoryView: View {
    @Bindable var history: HistoryModel
    let app: ClipApp

    @State private var showingPair = false
    @State private var renaming: ClipItem?
    @State private var renameText = ""
    @State private var tagging: ClipItem?
    @State private var tagText = ""

    var body: some View {
        NavigationStack {
            List {
                if !history.pinned.isEmpty {
                    Section(Strings.sectionPinned) {
                        ForEach(history.pinned) { row($0) }
                    }
                }
                if !history.recent.isEmpty {
                    Section(Strings.sectionRecent) {
                        ForEach(history.recent) { row($0) }
                        if history.canLoadMore {
                            Button(Strings.loadMore) {
                                Task { await history.loadMore() }
                            }
                        }
                    }
                }
            }
            .overlay {
                if history.isEmpty {
                    if history.searchText.isEmpty {
                        ContentUnavailableView(
                            Strings.historyTitle, systemImage: "doc.on.clipboard",
                            description: Text(Strings.emptyHistory))
                    } else {
                        ContentUnavailableView(Strings.noResults, systemImage: "magnifyingglass")
                    }
                }
            }
            .navigationTitle(Strings.historyTitle)
            .searchable(text: $history.searchText, prompt: Strings.searchPrompt)
            .refreshable { await history.syncNow() }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingPair = true
                    } label: {
                        Label(Strings.menuPairDevice, systemImage: "iphone.and.arrow.forward")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // F2: the system paste button reads the clipboard without the "Allow Paste" prompt.
                    PasteButton(payloadType: String.self) { strings in
                        guard let text = strings.first else { return }
                        Task { @MainActor in await history.send(text) }
                    }
                    .buttonBorderShape(.capsule)
                }
                ToolbarItem(placement: .status) {
                    Text(history.syncStatus.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toolbar(.visible, for: .bottomBar)
            .sheet(isPresented: $showingPair) {
                PairView(app: app) { showingPair = false }
                    .presentationDetents([.medium])
            }
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
                    .textInputAutocapitalization(.never)
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
            // copyCount, not lastCopied: copying the same item twice still changes it, so it buzzes again.
            .sensoryFeedback(.success, trigger: history.copyCount)
        }
        .onAppear { history.setVisible(true) }
        .onDisappear { history.setVisible(false) }
    }

    private func row(_ item: ClipItem) -> some View {
        Button {
            history.copy(item)  // F3
        } label: {
            HistoryRow(item: item, justCopied: history.lastCopied == item.id)
        }
        .tint(.primary)
        .swipeActions(edge: .leading) {
            Button {
                Task { await history.togglePin(item) }
            } label: {
                Label(item.isPinned ? Strings.actionUnpin : Strings.actionPin,
                      systemImage: item.isPinned ? "pin.slash" : "pin")
            }
            .tint(.orange)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                Task { await history.delete(item) }
            } label: {
                Label(Strings.actionDelete, systemImage: "trash")
            }
        }
        .contextMenu {
            Button {
                history.copy(item)
            } label: {
                Label(Strings.actionCopy, systemImage: "doc.on.doc")
            }
            Button {
                renameText = item.title ?? ""
                renaming = item
            } label: {
                Label(Strings.actionRename, systemImage: "pencil")
            }
            Button {
                tagText = ""
                tagging = item
            } label: {
                Label(Strings.actionAddTag, systemImage: "tag")
            }
            ForEach(item.tags, id: \.self) { tag in
                Button {
                    Task { await history.removeTag(item, tag) }
                } label: {
                    Label(Strings.format(Strings.actionRemoveTag, ["tag": tag]), systemImage: "tag.slash")
                }
            }
            Button(role: .destructive) {
                Task { await history.delete(item) }
            } label: {
                Label(Strings.actionDelete, systemImage: "trash")
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
