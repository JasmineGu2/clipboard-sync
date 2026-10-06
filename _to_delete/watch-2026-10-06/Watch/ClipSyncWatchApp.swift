import ClipAppCore
import SwiftUI

@main
struct ClipSyncWatchApp: App {
    @State private var store = WatchStore.live()

    var body: some Scene {
        WindowGroup {
            PinnedListView(store: store)
        }
    }
}

/// F17: the iPhone's pinned items, newest first.
struct PinnedListView: View {
    let store: WatchStore

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.payload.items) { item in
                    NavigationLink(value: item) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.headline)
                                .font(.headline)
                                .lineLimit(2)
                            if !item.tags.isEmpty {
                                Text(item.tags.joined(separator: " · "))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                if store.payload.omittedCount > 0 {
                    Text(Strings.format(Strings.watchOmitted, ["count": String(store.payload.omittedCount)]))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }
            }
            .overlay {
                if store.payload.items.isEmpty {
                    ContentUnavailableView(
                        Strings.sectionPinned, systemImage: "pin",
                        description: Text(Strings.watchEmpty))
                }
            }
            .navigationTitle(Strings.sectionPinned)
            .navigationDestination(for: WatchPinnedItem.self) { item in
                PinnedDetailView(item: item, store: store)
            }
        }
    }
}

/// One item, large. The watch has no clipboard, so the text is for reading, or for copying on the iPhone.
struct PinnedDetailView: View {
    let item: WatchPinnedItem
    let store: WatchStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let title = item.title, !title.isEmpty {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                Text(item.text)
                    .font(.title3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if item.isTruncated {
                    Text(Strings.watchTruncated)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if !item.tags.isEmpty {
                    Text(item.tags.joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Button {
                    Task { await store.copyOnPhone(item) }
                } label: {
                    Label(Strings.watchCopyOnPhone, systemImage: "iphone")
                }
                .disabled(store.copyState == .sending(item.id))
                status
            }
        }
        .sensoryFeedback(.success, trigger: store.copyState == .copied(item.id))
    }

    @ViewBuilder private var status: some View {
        switch store.copyState {
        case .copied(item.id):
            Text(Strings.watchCopiedOnPhone).font(.footnote).foregroundStyle(.green)
        case .failed(item.id):
            Text(Strings.watchPhoneUnreachable).font(.footnote).foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }
}

#if DEBUG
#Preview("Pinned") {
    PinnedListView(store: WatchStore(link: nil, fileURL: nil, initial: WatchPreviewSeed.payload))
}

#Preview("Empty") {
    PinnedListView(store: WatchStore(link: nil, fileURL: nil, initial: .empty))
}
#endif
