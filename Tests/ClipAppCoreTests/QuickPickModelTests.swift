import ClipCore
import ClipCrypto
import ClipStore
import ClipSync
import Foundation
import XCTest
@testable import ClipAppCore

/// The Mac's ⌃⌘V picker state: what it lists, searching, and the keyboard selection.
@MainActor
final class QuickPickModelTests: XCTestCase {
    func makeHistory(_ texts: [String]) async throws -> HistoryModel {
        let db = try ClipDatabase.inMemory()
        let engine = try SyncEngine(
            db: db, vaultKey: VaultKey.generate(), transport: OfflineTransport(), device: DeviceID(),
            deviceName: "Mac", log: { _ in })
        for text in texts { try await engine.addText(text) }
        return HistoryModel(engine: engine, db: db, pasteboard: FakePasteboard())
    }

    func testListsNewestFirstIncludingPinnedAndStopsAtTheLimit() async throws {
        let history = try await makeHistory((1...8).map { "clip \($0)" })
        await history.refresh()
        await history.togglePin(try XCTUnwrap(history.recent.last))  // "clip 1", the oldest
        let picker = QuickPickModel(history: history, limit: 5)
        await picker.reset()
        XCTAssertEqual(picker.items.map(\.text), ["clip 8", "clip 7", "clip 6", "clip 5", "clip 4"])
        XCTAssertEqual(picker.selectedItem?.text, "clip 8")
    }

    func testSearchNarrowsAndResetsTheSelection() async throws {
        let history = try await makeHistory(["invoice 42", "lunch order", "invoice 43", "meeting notes"])
        let picker = QuickPickModel(history: history, debounce: .milliseconds(10))
        await picker.reset()
        picker.moveSelection(by: 2)
        XCTAssertEqual(picker.selection, 2)
        picker.query = "invoice"
        await picker.waitForReload()
        XCTAssertEqual(picker.items.map(\.text), ["invoice 43", "invoice 42"])
        XCTAssertEqual(picker.selection, 0)
        // The menu's own search is untouched.
        XCTAssertEqual(history.searchText, "")
    }

    func testSelectionStopsAtBothEnds() async throws {
        let history = try await makeHistory(["a", "b", "c"])
        let picker = QuickPickModel(history: history)
        await picker.reset()
        picker.moveSelection(by: -1)
        XCTAssertEqual(picker.selectedItem?.text, "c")
        picker.moveSelection(by: 1)
        picker.moveSelection(by: 1)
        picker.moveSelection(by: 1)
        XCTAssertEqual(picker.selectedItem?.text, "a")
        picker.select(try XCTUnwrap(picker.items.first))
        XCTAssertEqual(picker.selection, 0)
    }

    func testEmptyHistoryHasNoSelection() async throws {
        let picker = QuickPickModel(history: try await makeHistory([]))
        await picker.reset()
        picker.moveSelection(by: 1)
        XCTAssertTrue(picker.items.isEmpty)
        XCTAssertNil(picker.selectedItem)
    }

    func testResetClearsAnOldQuery() async throws {
        let history = try await makeHistory(["alpha", "beta"])
        let picker = QuickPickModel(history: history, debounce: .milliseconds(10))
        picker.query = "alpha"
        await picker.waitForReload()
        XCTAssertEqual(picker.items.count, 1)
        await picker.reset()
        XCTAssertEqual(picker.query, "")
        XCTAssertEqual(picker.items.count, 2)
    }
}
