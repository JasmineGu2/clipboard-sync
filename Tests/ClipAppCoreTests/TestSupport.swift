import ClipCore
import ClipCrypto
import ClipStore
import ClipSync
import ClipWire
import Foundation
@testable import ClipAppCore

/// Stands in for NSPasteboard/UIPasteboard.
@MainActor
final class FakePasteboard: PasteboardWriter, PasteboardReader {
    private(set) var written: [String] = []
    private(set) var changeCount = 0
    private var contents = PasteboardContents(types: [], text: nil)

    func write(text: String) {
        written.append(text)
        set(types: ["public.utf8-plain-text", CaptureFilter.ownMarkerType], text: text)
    }

    /// Another app copied something.
    func set(types: [String], text: String?) {
        contents = PasteboardContents(types: types, text: text)
        changeCount += 1
    }

    func read() -> PasteboardContents { contents }
}

/// A relay that never answers pushes or pulls until cancelled.
struct HangingTransport: SyncTransport {
    func push(_ request: PushRequest) async throws -> PushResponse {
        try await Task.sleep(for: .seconds(3600))
        throw TransportError.network("hung")
    }

    func pull(after: Int64, limit: Int, wait: Int) async throws -> PullResponse {
        try await Task.sleep(for: .seconds(3600))
        throw TransportError.network("hung")
    }

    func putPairing(id: String, blob: Data) async throws {}
    func takePairing(id: String) async throws -> Data? { nil }

    func putDevice(_ record: DeviceRecord) async throws {
        try await Task.sleep(for: .seconds(3600))
        throw TransportError.network("hung")
    }

    func listDevices() async throws -> [DeviceRecord] {
        try await Task.sleep(for: .seconds(3600))
        throw TransportError.network("hung")
    }

    func revoke(_ request: RevokeRequest) async throws -> RevokeResponse {
        try await Task.sleep(for: .seconds(3600))
        throw TransportError.network("hung")
    }

    func handoffs(deviceID: String) async throws -> [Data] { [] }
}

/// A relay that's down.
struct OfflineTransport: SyncTransport {
    func push(_ request: PushRequest) async throws -> PushResponse { throw TransportError.network("offline") }
    func pull(after: Int64, limit: Int, wait: Int) async throws -> PullResponse { throw TransportError.network("offline") }
    func putPairing(id: String, blob: Data) async throws { throw TransportError.network("offline") }
    func takePairing(id: String) async throws -> Data? { throw TransportError.network("offline") }
    func putDevice(_ record: DeviceRecord) async throws { throw TransportError.network("offline") }
    func listDevices() async throws -> [DeviceRecord] { throw TransportError.network("offline") }
    func revoke(_ request: RevokeRequest) async throws -> RevokeResponse { throw TransportError.network("offline") }
    func handoffs(deviceID: String) async throws -> [Data] { throw TransportError.network("offline") }
}

/// A fresh, empty directory per call.
func makeHome() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("ClipAppCoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func factory(_ transport: any SyncTransport) -> TransportFactory {
    { _, _ in transport }
}
