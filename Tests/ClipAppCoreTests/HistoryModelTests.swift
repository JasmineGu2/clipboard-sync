import ClipCore
import ClipCrypto
import ClipStore
import ClipSync
import Foundation
import XCTest
@testable import ClipAppCore

@MainActor
final class HistoryModelTests: XCTestCase {
    let key = VaultKey.generate()

    struct Fixture {
        let model: HistoryModel
        let engine: SyncEngine
        let db: ClipDatabase
        let pasteboard: FakePasteboard
    }

    func makeFixture(
        _ transport: any SyncTransport = InMemoryRelay(), name: String = "Mac", pageSize: Int = 200,
        debounce: Duration = .milliseconds(50), copiedDuration: Duration = .milliseconds(1500)
    ) throws -> Fixture {
        let db = try ClipDatabase.inMemory()
        let engine = try SyncEngine(
            db: db, vaultKey: key, transport: transport, device: DeviceID(), deviceName: name, log: { _ in })
        let pasteboard = FakePasteboard()
        let model = HistoryModel(
            engine: engine, db: db, pasteboard: pasteboard, pageSize: pageSize, debounce: debounce,
            copiedDuration: copiedDuration)
        return Fixture(model: model, engine: engine, db: db, pasteboard: pasteboard)
    }

    func testSendAddsItemAndSyncsToAnotherDevice() async throws {
        let relay = InMemoryRelay()
        let a = try makeFixture(relay, name: "Mac")
        let b = try makeFixture(relay, name: "iPhone")

        let sent = await a.model.send("hello from the mac")
        XCTAssertTrue(sent)
        XCTAssertEqual(a.model.recent.map(\.text), ["hello from the mac"])
        XCTAssertEqual(a.model.recent.first?.sourceDeviceName, "Mac")
        guard case .synced = a.model.syncStatus else { return XCTFail("expected synced, got \(a.model.syncStatus)") }

        await b.model.syncNow()
        XCTAssertEqual(b.model.recent.map(\.text), ["hello from the mac"])
    }

    func testSendEmptyTextShowsMessage() async throws {
        let f = try makeFixture()
        let sent = await f.model.send("   \n ")
        XCTAssertFalse(sent)
        XCTAssertEqual(f.model.message, .emptyText)
        XCTAssertTrue(f.model.isEmpty)
    }

    func testSendWhileOfflineKeepsItemAndShowsOffline() async throws {
        let f = try makeFixture(OfflineTransport())
        let sent = await f.model.send("saved anyway")
        XCTAssertTrue(sent)
        XCTAssertNil(f.model.message)
        XCTAssertEqual(f.model.recent.map(\.text), ["saved anyway"])
        XCTAssertEqual(f.model.syncStatus, .offline)
        XCTAssertEqual(try f.db.pendingOutbound().count, 1)
    }

    func testSearchIsDebounced() async throws {
        let f = try makeFixture(debounce: .milliseconds(100))
        for text in ["apple pie", "banana bread", "apricot jam"] { await f.model.send(text) }
        XCTAssertEqual(f.model.searchQueryCount, 0)

        f.model.searchText = "a"
        f.model.searchText = "ap"
        f.model.searchText = "apr"
        await f.model.waitForSearch()

        XCTAssertEqual(f.model.searchQueryCount, 1, "three quick keystrokes run one query")
        XCTAssertEqual(f.model.recent.map(\.text), ["apricot jam"])

        f.model.searchText = ""
        await f.model.waitForSearch()
        XCTAssertEqual(f.model.recent.count, 3)
        XCTAssertEqual(f.model.searchQueryCount, 1, "an empty query lists items instead of searching")
    }

    func testPinnedItemsGetTheirOwnSection() async throws {
        let f = try makeFixture()
        for text in ["one", "two", "three"] { await f.model.send(text) }
        let two = try XCTUnwrap(f.model.recent.first { $0.text == "two" })

        await f.model.togglePin(two)
        XCTAssertEqual(f.model.pinned.map(\.text), ["two"])
        XCTAssertEqual(f.model.recent.map(\.text), ["three", "one"])

        let pinned = try XCTUnwrap(f.model.pinned.first)
        await f.model.togglePin(pinned)
        XCTAssertTrue(f.model.pinned.isEmpty)
        XCTAssertEqual(f.model.recent.map(\.text), ["three", "two", "one"])
    }

    func testRenameTagAndDelete() async throws {
        let f = try makeFixture()
        await f.model.send("ssh deploy@host")
        var item = try XCTUnwrap(f.model.recent.first)

        await f.model.rename(item, to: "  Deploy login ")
        item = try XCTUnwrap(f.model.recent.first)
        XCTAssertEqual(item.title, "Deploy login")
        XCTAssertEqual(item.headline, "Deploy login")

        await f.model.addTag(item, " work ")
        await f.model.addTag(item, "   ")
        item = try XCTUnwrap(f.model.recent.first)
        XCTAssertEqual(item.tags, ["work"])

        f.model.searchText = "work"
        await f.model.waitForSearch()
        XCTAssertEqual(f.model.recent.map(\.id), [item.id], "tags are searchable")
        f.model.searchText = ""
        await f.model.waitForSearch()

        await f.model.removeTag(item, "work")
        await f.model.rename(item, to: "")
        item = try XCTUnwrap(f.model.recent.first)
        XCTAssertEqual(item.tags, [])
        XCTAssertNil(item.title)
        XCTAssertEqual(item.headline, "ssh deploy@host")

        await f.model.delete(item)
        XCTAssertTrue(f.model.isEmpty)
    }

    func testCopyWritesToPasteboard() async throws {
        let f = try makeFixture()
        await f.model.send("copy me")
        let item = try XCTUnwrap(f.model.recent.first)
        f.model.copy(item)
        XCTAssertEqual(f.pasteboard.written, ["copy me"])
        XCTAssertEqual(f.model.lastCopied, item.id)
    }

    func testCopiedConfirmationClearsAndANewCopyRestartsTheClock() async throws {
        let f = try makeFixture(copiedDuration: .milliseconds(400))
        await f.model.send("first")
        await f.model.send("second")
        let second = try XCTUnwrap(f.model.recent.first)
        let first = try XCTUnwrap(f.model.recent.last)

        let start = ContinuousClock.now
        f.model.copy(first)
        XCTAssertEqual(f.model.lastCopied, first.id)
        try await Task.sleep(for: .milliseconds(250))
        f.model.copy(second)
        // Past the first copy's deadline (400 ms), before the second's (650 ms).
        try await Task.sleep(until: start + .milliseconds(500))
        XCTAssertEqual(f.model.lastCopied, second.id, "the second copy restarted the clock")

        await f.model.waitForCopiedReset()
        XCTAssertNil(f.model.lastCopied)
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - start, .milliseconds(650))
    }

    func testCopyCountBumpsOnEveryCopyOfTheSameItem() async throws {
        let f = try makeFixture()
        await f.model.send("again")
        let item = try XCTUnwrap(f.model.recent.first)
        XCTAssertEqual(f.model.copyCount, 0)

        f.model.copy(item)
        f.model.copy(item)
        XCTAssertEqual(f.model.copyCount, 2, "repeat copies still change the haptics trigger")
        XCTAssertEqual(f.model.lastCopied, item.id)
        f.model.stop()
    }

    func testPaging() async throws {
        let f = try makeFixture(pageSize: 10)
        for i in 0..<25 { await f.model.capture("clip \(i)") }
        await f.model.refresh()
        XCTAssertEqual(f.model.recent.count, 10)
        XCTAssertEqual(f.model.recent.first?.text, "clip 24")
        XCTAssertTrue(f.model.canLoadMore)

        await f.model.loadMore()
        XCTAssertEqual(f.model.recent.count, 20)
        await f.model.loadMore()
        XCTAssertEqual(f.model.recent.count, 25)
        XCTAssertFalse(f.model.canLoadMore)
        XCTAssertEqual(f.model.recent.last?.text, "clip 0")
    }

    func testRefreshesOnRemoteChanges() async throws {
        let relay = InMemoryRelay()
        let a = try makeFixture(relay)
        let b = try makeFixture(relay)
        b.model.start()
        defer { b.model.stop() }

        await a.model.send("arrives by itself")
        try await b.engine.syncOnce()  // Fires b.engine.changes; the model refreshes on its own.

        for _ in 0..<100 where b.model.recent.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(b.model.recent.map(\.text), ["arrives by itself"])
    }

    func testCaptureSkipsTextTooLargeForTheRelayWithoutAnAlert() async throws {
        let f = try makeFixture()
        let big = String(repeating: "x", count: 300 * 1024)  // Under the capture cap, over the relay's op cap.
        let captured = await f.model.capture(big)
        XCTAssertFalse(captured)
        XCTAssertNil(f.model.message)

        let sent = await f.model.send(big)
        XCTAssertFalse(sent)
        XCTAssertEqual(f.model.message, .tooLarge, "an explicit send does say why")
    }

    func testHeadlineUsesFirstNonEmptyLine() async throws {
        let f = try makeFixture()
        await f.model.send("\n\n   first line  \nsecond")
        XCTAssertEqual(f.model.recent.first?.headline, "first line")
    }
}
