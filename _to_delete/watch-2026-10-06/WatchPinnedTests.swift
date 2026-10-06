import ClipCore
import ClipCrypto
import ClipStore
import ClipSync
import Foundation
import XCTest
@testable import ClipAppCore

/// F17: the payload the iPhone sends the Apple Watch, and when HistoryModel sends it.
@MainActor
final class WatchPinnedTests: XCTestCase {
    // MARK: Building the payload

    func testOnlyPinnedItemsInTheGivenOrder() {
        let items = [
            ClipItem(text: "newest", title: "Wi-Fi", tags: ["home"], isPinned: true),
            ClipItem(text: "not pinned"),
            ClipItem(text: "older", isPinned: true),
        ]
        let payload = WatchPinnedPayload.build(from: items)
        XCTAssertEqual(payload.items.map(\.text), ["newest", "older"])
        XCTAssertEqual(payload.items.first?.title, "Wi-Fi")
        XCTAssertEqual(payload.items.first?.tags, ["home"])
        XCTAssertEqual(payload.items.first?.id, items[0].id.description)
        XCTAssertEqual(payload.items.map(\.headline), ["Wi-Fi", "older"])
        XCTAssertEqual(payload.omittedCount, 0)
        XCTAssertEqual(payload.version, WatchPinnedPayload.currentVersion)
    }

    func testNothingPinnedIsTheEmptyPayload() {
        XCTAssertEqual(WatchPinnedPayload.build(from: [ClipItem(text: "a")]), .empty)
        XCTAssertEqual(WatchPinnedPayload.build(from: []), .empty)
    }

    func testItemCapCountsTheRest() {
        let items = (0..<60).map { ClipItem(text: "item \($0)", isPinned: true) }
        let limits = WatchPayloadLimits(maxItems: 50, maxTextCharacters: 2_000, maxTotalBytes: 1_000_000)
        let payload = WatchPinnedPayload.build(from: items, limits: limits)
        XCTAssertEqual(payload.items.count, 50)
        XCTAssertEqual(payload.items.last?.text, "item 49")
        XCTAssertEqual(payload.omittedCount, 10)
    }

    func testLongTextIsCutAndMarked() {
        let long = String(repeating: "é", count: 2_500)  // multi-byte, so the cut must count characters
        let payload = WatchPinnedPayload.build(from: [ClipItem(text: long, isPinned: true)])
        let item = try! XCTUnwrap(payload.items.first)
        XCTAssertTrue(item.isTruncated)
        XCTAssertEqual(item.text.count, WatchPayloadLimits.standard.maxTextCharacters)
        XCTAssertFalse(WatchPinnedPayload.build(from: [ClipItem(text: "short", isPinned: true)]).items[0].isTruncated)
    }

    func testEncodedPayloadNeverExceedsTheByteBudget() throws {
        // Quotes, backslashes and control characters grow when JSON-escaped; the budget must use the real size.
        let nasty = String(repeating: "\"\\\u{01}\n", count: 500)
        let items = (0..<200).map { ClipItem(text: "\($0) \(nasty)", title: "t\"\($0)", tags: ["a\"b"], isPinned: true) }
        for budget in [500, 4_000, 20_000, WatchPayloadLimits.standard.maxTotalBytes] {
            let limits = WatchPayloadLimits(maxItems: 50, maxTextCharacters: 2_000, maxTotalBytes: budget)
            let payload = WatchPinnedPayload.build(from: items, limits: limits)
            let size = try payload.encoded().count
            XCTAssertLessThanOrEqual(size, budget, "budget \(budget)")
            XCTAssertEqual(payload.items.count + payload.omittedCount, 200)
        }
        // The real budget fits several of these items, so the cap isn't simply dropping everything.
        XCTAssertGreaterThan(WatchPinnedPayload.build(from: items).items.count, 5)
    }

    func testABigItemIsSkippedButSmallerOnesAfterItStillFit() {
        let items = [
            ClipItem(text: String(repeating: "x", count: 2_000), isPinned: true),
            ClipItem(text: "small", isPinned: true),
        ]
        let limits = WatchPayloadLimits(maxItems: 50, maxTextCharacters: 2_000, maxTotalBytes: 300)
        let payload = WatchPinnedPayload.build(from: items, limits: limits)
        XCTAssertEqual(payload.items.map(\.text), ["small"])
        XCTAssertEqual(payload.omittedCount, 1)
    }

    func testRoundTripAndVersionCheck() throws {
        let payload = WatchPinnedPayload.build(from: [ClipItem(text: "hello", title: "Hi", tags: ["x"], isPinned: true)])
        XCTAssertEqual(WatchPinnedPayload.decode(try payload.encoded()), payload)

        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload.encoded()) as? [String: Any])
        json["version"] = WatchPinnedPayload.currentVersion + 1
        XCTAssertNil(WatchPinnedPayload.decode(try JSONSerialization.data(withJSONObject: json)))
        XCTAssertNil(WatchPinnedPayload.decode(Data("not json".utf8)))
    }

    // MARK: HistoryModel sends it

    final class FakeMirror: PinnedItemsMirror {
        var published: [WatchPinnedPayload] = []
        func publish(_ payload: WatchPinnedPayload) { published.append(payload) }
    }

    let key = VaultKey.generate()

    func makeModel() throws -> (HistoryModel, FakeMirror, FakePasteboard) {
        let db = try ClipDatabase.inMemory()
        let engine = try SyncEngine(
            db: db, vaultKey: key, transport: InMemoryRelay(), device: DeviceID(), deviceName: "iPhone", log: { _ in })
        let pasteboard = FakePasteboard()
        let model = HistoryModel(engine: engine, db: db, pasteboard: pasteboard, debounce: .milliseconds(10))
        let mirror = FakeMirror()
        model.pinnedMirror = mirror
        return (model, mirror, pasteboard)
    }

    func testPublishesOnPinChangesOnly() async throws {
        let (model, mirror, _) = try makeModel()
        await model.send("first")
        XCTAssertEqual(mirror.published, [.empty], "the first load sends the (empty) state once")

        await model.togglePin(try XCTUnwrap(model.recent.first))
        XCTAssertEqual(mirror.published.last?.items.map(\.text), ["first"])
        let count = mirror.published.count

        await model.send("unpinned arrival")
        await model.syncNow()
        XCTAssertEqual(mirror.published.count, count, "an unpinned change doesn't resend")

        await model.rename(try XCTUnwrap(model.pinned.first), to: "Renamed")
        XCTAssertEqual(mirror.published.last?.items.first?.title, "Renamed")

        await model.togglePin(try XCTUnwrap(model.pinned.first))
        XCTAssertEqual(mirror.published.last, .empty)
    }

    func testSearchStillSendsEveryPinnedItem() async throws {
        let (model, mirror, _) = try makeModel()
        await model.send("apple")
        await model.send("banana")
        for item in model.recent { await model.togglePin(item) }

        model.searchText = "apple"
        await model.waitForSearch()
        XCTAssertEqual(model.pinned.map(\.text), ["apple"], "the screen shows search results")
        XCTAssertEqual(Set(mirror.published.last?.items.map(\.text) ?? []), ["apple", "banana"])

        // A pin change during a search still reaches the watch.
        await model.togglePin(try XCTUnwrap(model.pinned.first))
        XCTAssertEqual(mirror.published.last?.items.map(\.text), ["banana"])
    }

    func testCopyPinnedCopiesFullTextOfPinnedItemsOnly() async throws {
        let (model, _, pasteboard) = try makeModel()
        let long = String(repeating: "z", count: 3_000)
        await model.send(long)
        await model.send("not pinned")
        let longItem = try XCTUnwrap(model.recent.first { $0.text == long })
        await model.togglePin(longItem)

        XCTAssertTrue(model.copyPinned(id: longItem.id.description))
        XCTAssertEqual(pasteboard.written.last, long, "the phone copies the full text, not the watch's cut")

        let unpinned = try XCTUnwrap(model.recent.first)
        XCTAssertFalse(model.copyPinned(id: unpinned.id.description))
        XCTAssertFalse(model.copyPinned(id: "nonsense"))
        XCTAssertEqual(pasteboard.written.count, 1)
    }

    func testNoMirrorNoExtraWork() async throws {
        let (model, _, _) = try makeModel()
        model.pinnedMirror = nil
        await model.send("x")
        XCTAssertFalse(model.copyPinned(id: try XCTUnwrap(model.recent.first).id.description))
    }
}
