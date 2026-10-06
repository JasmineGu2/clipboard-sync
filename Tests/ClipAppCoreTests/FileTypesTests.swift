import ClipCore
import Foundation
import XCTest
#if canImport(ImageIO)
import CoreGraphics
import ImageIO
#endif
@testable import ClipAppCore

final class FileTypesTests: XCTestCase {
    func testContentTypeAndKind() {
        XCTAssertEqual(FileTypes.contentType(forName: "Shot.PNG"), "image/png")
        XCTAssertEqual(FileTypes.kind(forContentType: "image/png"), .image)
        XCTAssertEqual(FileTypes.kind(forContentType: "application/pdf"), .file)
        XCTAssertEqual(FileTypes.kind(forContentType: nil), .file)
        XCTAssertNil(FileTypes.contentType(forName: "archive.weird"))
        XCTAssertEqual(FileTypes.fileExtension(forContentType: "image/jpeg"), "jpeg")
    }

    func testSafeFileNameStripsFoldersAndControlCharacters() {
        XCTAssertEqual(FileTypes.safeFileName("../../etc/passwd", fallback: "x"), "_.._etc_passwd")
        XCTAssertEqual(FileTypes.safeFileName("a\u{0}b:c.txt", fallback: "x"), "a_b_c.txt")
        XCTAssertEqual(FileTypes.safeFileName(" .. ", fallback: "item"), "item")
        XCTAssertEqual(FileTypes.safeFileName("photo.jpg", fallback: "x"), "photo.jpg")
    }

    func testSizeText() {
        XCTAssertEqual(FileTypes.sizeText(0), "0 bytes")
        XCTAssertEqual(FileTypes.sizeText(999), "999 bytes")
        XCTAssertEqual(FileTypes.sizeText(2_400_000), "2.4 MB")
        XCTAssertEqual(FileTypes.sizeText(52_428_800), "52 MB")
    }

    #if canImport(ImageIO) && canImport(CoreGraphics)
    /// A 1000 x 600 PNG becomes a JPEG thumbnail under the cap, at most 256 px on its long side.
    func testImageIOThumbnailFitsTheCap() throws {
        let png = try XCTUnwrap(Self.makePNG(width: 1000, height: 600))
        let thumb = try XCTUnwrap(ImageIOThumbnailMaker().thumbnail(for: png, maxBytes: ItemContent.maxThumbnailBytes))
        XCTAssertLessThanOrEqual(thumb.count, ItemContent.maxThumbnailBytes)
        XCTAssertEqual(Array(thumb.prefix(2)), [0xFF, 0xD8], "JPEG")
        XCTAssertNil(ImageIOThumbnailMaker().thumbnail(for: Data("not an image".utf8), maxBytes: 10_000))
    }

    static func makePNG(width: Int, height: Int) -> Data? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        for x in stride(from: 0, to: width, by: 10) {
            context.setFillColor(red: CGFloat(x) / CGFloat(width), green: 0.3, blue: 0.6, alpha: 1)
            context.fill(CGRect(x: x, y: 0, width: 10, height: height))
        }
        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
    #endif
}
