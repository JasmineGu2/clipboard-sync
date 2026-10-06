import ClipCore
import ClipCrypto
import ClipStore
import ClipSync
import Foundation
import XCTest
@testable import ClipAppCore

/// Images and files in the app layer (F11, F12): what the watcher captures, copying (download first), and the
/// share extension's one-shot file send.
@MainActor
final class BlobAppTests: XCTestCase {
    let key = VaultKey.generate()
    let server = "http://relay.test:8080"

    struct Fixture {
        let model: HistoryModel
        let engine: SyncEngine
        let db: ClipDatabase
        let pasteboard: FakePasteboard
        let home: URL
    }

    func makeFixture(_ transport: any SyncTransport, name: String) throws -> Fixture {
        let home = try makeHome()
        let db = try ClipDatabase.inMemory()
        let engine = try SyncEngine(
            db: db, vaultKey: key, transport: transport, device: DeviceID(), deviceName: name, log: { _ in },
            blobCache: try BlobCache(directory: home.appendingPathComponent("blobs")))
        let pasteboard = FakePasteboard()
        let model = HistoryModel(engine: engine, db: db, pasteboard: pasteboard,
                                 exportsDirectory: home.appendingPathComponent("exports"))
        return Fixture(model: model, engine: engine, db: db, pasteboard: pasteboard, home: home)
    }

    func file(_ name: String, bytes: Data, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    // MARK: CaptureFilter

    func testFilesBeatTextAndTextBeatsImages() {
        let png = PasteboardImage(data: Data([1, 2, 3]), contentType: "image/png")
        let a = URL(fileURLWithPath: "/tmp/a.txt"), folder = URL(fileURLWithPath: "/tmp/folder")
        let sizes: (URL) -> Int64? = { $0 == folder ? nil : 10 }
        func decide(_ contents: PasteboardContents) -> CaptureFilter.ClipDecision { CaptureFilter.decide(contents, fileSize: sizes) }

        // Finder: file URLs plus the name as text plus an icon.
        XCTAssertEqual(decide(.init(types: ["public.file-url"], text: "a.txt", fileURLs: [a, folder], image: png)),
                       .capture(.files([a])))
        // Office: text plus a picture of it.
        XCTAssertEqual(decide(.init(types: ["public.utf8-plain-text", "public.png"], text: "cells", image: png)),
                       .capture(.text("cells")))
        // A screenshot.
        XCTAssertEqual(decide(.init(types: ["public.png"], text: nil, image: png)), .capture(.image(png)))
        // Only a folder.
        XCTAssertEqual(decide(.init(types: ["public.file-url"], text: nil, fileURLs: [folder])), .empty)
    }

    func testPrivacyMarkersStillWinForImagesAndFiles() {
        let png = PasteboardImage(data: Data([1]), contentType: "image/png")
        let url = URL(fileURLWithPath: "/tmp/secret.key")
        XCTAssertEqual(CaptureFilter.decide(
            .init(types: [CaptureFilter.concealedType, "public.file-url"], text: nil, fileURLs: [url]), fileSize: { _ in 1 }),
            .concealed)
        XCTAssertEqual(CaptureFilter.decide(
            .init(types: [CaptureFilter.transientType, "public.png"], text: nil, image: png), fileSize: { _ in 1 }),
            .concealed)
        XCTAssertEqual(CaptureFilter.decide(
            .init(types: [CaptureFilter.ownMarkerType, "public.file-url"], text: nil, fileURLs: [url]), fileSize: { _ in 1 }),
            .ownWrite)
    }

    func testSizeCaps() {
        let url = URL(fileURLWithPath: "/tmp/movie.mov")
        XCTAssertEqual(CaptureFilter.decide(.init(types: [], text: nil, fileURLs: [url]),
                                            fileSize: { _ in CaptureFilter.maxAutoCaptureFileBytes + 1 }), .tooLarge)
        let big = PasteboardImage(data: Data(count: CaptureFilter.maxImageBytes + 1), contentType: "image/png")
        XCTAssertEqual(CaptureFilter.decide(.init(types: [], text: nil, image: big), fileSize: { _ in nil }), .tooLarge)
    }

    func testPollerHandsOverClipsAndRespectsPause() {
        let pasteboard = FakePasteboard()
        let poller = ClipboardPoller(reader: pasteboard)
        let png = PasteboardImage(data: Data([9]), contentType: "image/png")
        pasteboard.set(PasteboardContents(types: ["public.png"], text: nil, image: png))
        XCTAssertEqual(poller.pollClip(), .image(png))
        XCTAssertNil(poller.pollClip(), "no change, nothing new")
        poller.isPaused = true
        pasteboard.set(PasteboardContents(types: ["public.png"], text: nil, image: png))
        XCTAssertNil(poller.pollClip())
        // Text-only callers never see images.
        poller.isPaused = false
        pasteboard.set(PasteboardContents(types: ["public.png"], text: nil, image: png))
        XCTAssertNil(poller.poll())
    }

    // MARK: HistoryModel

    func testCapturedImageSyncsAndCopiesOnAnotherDevice() async throws {
        let relay = InMemoryRelay()
        let mac = try makeFixture(relay, name: "Mac")
        let phone = try makeFixture(relay, name: "iPhone")
        let bytes = Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        let captured = await mac.model.capture(.image(PasteboardImage(data: bytes, contentType: "image/png")))
        XCTAssertTrue(captured)
        let item = try XCTUnwrap(mac.model.recent.first)
        XCTAssertEqual(item.kind, .image)
        XCTAssertEqual(item.text, "Clipboard image.png")
        XCTAssertEqual(item.fileSize, 3_000_000)
        try await mac.engine.syncOnce()
        try await mac.engine.uploadPendingBlobs()

        await phone.model.syncNow()
        let row = try XCTUnwrap(phone.model.recent.first)
        XCTAssertTrue(row.isFile)
        XCTAssertTrue(phone.pasteboard.writtenFiles.isEmpty, "a remote image doesn't land on the clipboard by itself")
        await phone.model.copyFile(row)
        let written = try XCTUnwrap(phone.pasteboard.writtenFiles.last)
        XCTAssertEqual(written.url.lastPathComponent, "Clipboard image.png")
        XCTAssertEqual(written.contentType, "image/png")
        XCTAssertEqual(try Data(contentsOf: written.url), bytes)
        XCTAssertEqual(phone.model.lastCopied, row.id)
        XCTAssertTrue(phone.model.downloading.isEmpty)
        XCTAssertNil(phone.model.message)
    }

    func testCopyBeforeTheUploadShowsAMessage() async throws {
        let relay = InMemoryRelay()
        let mac = try makeFixture(relay, name: "Mac")
        let phone = try makeFixture(relay, name: "iPhone")
        let url = try file("notes.pdf", bytes: Data(repeating: 1, count: 100), in: mac.home)
        let sent = await mac.model.sendFile(url)  // pushes the item; the upload is the run loop's job
        XCTAssertTrue(sent)
        await phone.model.syncNow()
        await phone.model.copyFile(try XCTUnwrap(phone.model.recent.first))
        XCTAssertEqual(phone.model.message, .notUploadedYet)
        XCTAssertTrue(phone.pasteboard.writtenFiles.isEmpty)
    }

    func testCapturedFilesKeepTheirNamesAndTypes() async throws {
        let mac = try makeFixture(InMemoryRelay(), name: "Mac")
        let a = try file("report.pdf", bytes: Data("pdf".utf8), in: mac.home)
        let b = try file("data.bin", bytes: Data("bin".utf8), in: mac.home)
        let captured = await mac.model.capture(.files([a, b]))
        XCTAssertTrue(captured)
        XCTAssertEqual(Set(mac.model.recent.map(\.text)), ["report.pdf", "data.bin"])
        XCTAssertEqual(Set(mac.model.recent.compactMap(\.contentType)), ["application/pdf"])
        XCTAssertTrue(mac.model.recent.allSatisfy { $0.kind == .file })
    }

    func testOldExportsAreCleanedUp() throws {
        let exports = try makeHome()
        let old = exports.appendingPathComponent("old"), fresh = exports.appendingPathComponent("fresh")
        for folder in [old, fresh] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-2 * 86_400)], ofItemAtPath: old.path)
        HistoryModel.cleanExports(in: exports, olderThan: 86_400)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: exports.path), ["fresh"])
    }

    // MARK: sendFileOnce (share extension)

    func makeReadyHome(relay: any SyncTransport) async throws -> (URL, InMemoryKeyStore) {
        let home = try makeHome()
        let keyStore = InMemoryKeyStore()
        let app = ClipApp.bootstrap(home: home, keyStore: keyStore, deviceName: "iPhone", pasteboard: FakePasteboard(),
                                    makeTransport: factory(relay), autoSync: false)
        await app.createVault(server: server)
        app.stop()
        return (home, keyStore)
    }

    func testShareExtensionSendsAFileAndItsBytes() async throws {
        let relay = InMemoryRelay()
        let (home, keyStore) = try await makeReadyHome(relay: relay)
        let url = try file("photo.jpg", bytes: Data(repeating: 7, count: 2_000_000), in: try makeHome())
        let result = await ClipApp.sendFileOnce(url, home: home, keyStore: keyStore, makeTransport: factory(relay))
        XCTAssertEqual(result, .sent)
        let db = try ClipDatabase(url: home.appendingPathComponent(ClipApp.databaseFileName))
        let item = try XCTUnwrap(try db.items().first)
        XCTAssertEqual(item.content?.kind, .image)
        XCTAssertEqual(item.content?.text, "photo.jpg")
        let blob = try XCTUnwrap(item.content?.blob).id.description
        let status = try await relay.blobStatus(blobID: blob)
        XCTAssertEqual(status?.isComplete, true)
        XCTAssertEqual(try db.pendingBlobUploads(), [])
    }

    func testShareExtensionOfflineKeepsTheUploadQueued() async throws {
        let (home, keyStore) = try await makeReadyHome(relay: InMemoryRelay())
        let url = try file("a.zip", bytes: Data(repeating: 1, count: 10), in: try makeHome())
        let result = await ClipApp.sendFileOnce(
            url, home: home, keyStore: keyStore, timeout: .milliseconds(200), makeTransport: factory(HangingTransport()))
        XCTAssertEqual(result, .savedOffline)
        let db = try ClipDatabase(url: home.appendingPathComponent(ClipApp.databaseFileName))
        XCTAssertEqual(try db.pendingBlobUploads().count, 1, "the app uploads it later")
        XCTAssertEqual(try db.pendingOutbound().count, 1)
    }
}
