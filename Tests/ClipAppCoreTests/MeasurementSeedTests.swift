import ClipCrypto
import ClipStore
import Foundation
import XCTest
@testable import ClipAppCore

/// The DEBUG seed behind the N3/N4 measurements: a ready vault with N items, seeded once.
@MainActor
final class MeasurementSeedTests: XCTestCase {
    func testSeedsOnceAndBootsReady() async throws {
        let home = try makeHome()
        let keys = InMemoryKeyStore()
        let key = VaultKey.generate()
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:9"))
        XCTAssertEqual(try ClipApp.seedForMeasurement(
            home: home, key: key, keyStore: keys, count: 1_200, serverURL: url, deviceName: "Bench"), 1_200)
        // A second launch finds them and adds nothing.
        XCTAssertEqual(try ClipApp.seedForMeasurement(
            home: home, key: key, keyStore: keys, count: 1_200, serverURL: url, deviceName: "Bench"), 1_200)
        XCTAssertEqual(try ClipDatabase(url: home.appendingPathComponent(ClipApp.databaseFileName)).count(), 1_200)

        let app = ClipApp.bootstrap(
            home: home, keyStore: keys, deviceName: "Bench", pasteboard: FakePasteboard(),
            makeTransport: factory(OfflineTransport()), autoSync: false)
        defer { app.stop() }
        XCTAssertEqual(app.state, .ready)
        let history = try XCTUnwrap(app.history)
        await history.refresh()
        XCTAssertEqual(history.recent.count, history.pageSize)
        XCTAssertEqual(history.recent.first?.text.hasPrefix("flight note 1199"), true)
    }
}
