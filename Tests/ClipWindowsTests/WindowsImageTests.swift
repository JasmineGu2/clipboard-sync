import Foundation
import XCTest
@testable import ClipWindows

/// The CF_DIB that synced images carry on Windows, so they paste into Figma, browsers and Paint.
/// Windows only; elsewhere the class is empty.
final class WindowsImageTests: XCTestCase {
    #if os(Windows)
    /// A 2×3 solid red PNG (RGB, 8 bits), made with Python's zlib.
    static let redPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAIAAAADCAIAAAA2iEnWAAAAEElEQVR4nGP4z8AARAwoFABE0AX7pM/egAAAAABJRU5ErkJggg==")!

    func testPNGDecodesToA32BitBottomUpDIB() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("red-\(UUID().uuidString).png")
        try Self.redPNG.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let dib = try XCTUnwrap(WindowsImage.dib(fromImageAt: url))
        XCTAssertEqual(dib.count, 40 + 2 * 3 * 4)
        func int32(_ offset: Int) -> Int32 { dib.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: Int32.self) } }
        func uint16(_ offset: Int) -> UInt16 { dib.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self) } }
        XCTAssertEqual(int32(0), 40, "biSize")
        XCTAssertEqual(int32(4), 2, "width")
        XCTAssertEqual(int32(8), 3, "height, positive for bottom-up")
        XCTAssertEqual(uint16(14), 32, "bits per pixel")
        // Every pixel is red, stored blue, green, red.
        for pixel in 0..<6 {
            let base = 40 + pixel * 4
            XCTAssertEqual(Array(dib[base..<base + 3]), [0x00, 0x00, 0xff], "pixel \(pixel)")
        }
    }

    func testNotAnImageGivesNil() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("not-\(UUID().uuidString).png")
        try Data("not a png".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(WindowsImage.dib(fromImageAt: url))
    }
    #endif
}
