import ClipCore
import Foundation
#if canImport(ImageIO) && canImport(CoreGraphics)
import CoreGraphics
import ImageIO
#endif

/// Makes the small JPEG preview that travels inside an image item's create op (F11). Platform code: the
/// Apple implementation uses ImageIO; elsewhere `NoThumbnails` sends images without one.
public protocol ThumbnailMaker: Sendable {
    /// A JPEG of at most `maxBytes`, or nil when the file isn't an image this platform can read.
    func thumbnail(forFileAt url: URL, maxBytes: Int) -> Data?
    func thumbnail(for data: Data, maxBytes: Int) -> Data?
}

public struct NoThumbnails: ThumbnailMaker {
    public init() {}
    public func thumbnail(forFileAt url: URL, maxBytes: Int) -> Data? { nil }
    public func thumbnail(for data: Data, maxBytes: Int) -> Data? { nil }
}

/// What the item's content type and kind should be, from a file name. Small on purpose: anything else is a
/// file of type application/octet-stream.
public enum FileTypes {
    static let byExtension: [String: String] = [
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "heic": "image/heic",
        "heif": "image/heif", "webp": "image/webp", "tif": "image/tiff", "tiff": "image/tiff", "bmp": "image/bmp",
        "pdf": "application/pdf", "txt": "text/plain", "md": "text/markdown", "json": "application/json",
        "zip": "application/zip", "csv": "text/csv", "html": "text/html", "mp4": "video/mp4", "mov": "video/quicktime",
        "mp3": "audio/mpeg",
    ]

    public static func contentType(forName name: String) -> String? {
        let ext = (name as NSString).pathExtension.lowercased()
        return byExtension[ext]
    }

    public static func kind(forContentType type: String?) -> ContentKind {
        type?.hasPrefix("image/") == true ? .image : .file
    }

    /// The file extension for a content type, for naming an image that came from a clipboard.
    public static func fileExtension(forContentType type: String) -> String? {
        byExtension.filter { $0.value == type }.keys.sorted().first
    }

    /// A name safe to save under: no folders, no control characters, not empty.
    public static func safeFileName(_ name: String, fallback: String) -> String {
        let cleaned = name.unicodeScalars.map { scalar -> Character in
            if scalar.value < 0x20 || "/\\:*?\"<>|".unicodeScalars.contains(scalar) { return "_" }
            return Character(scalar)
        }
        let trimmed = String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return trimmed.isEmpty ? fallback : String(trimmed.prefix(200))
    }

    /// "312 KB", "4.2 MB": decimal units, like Finder.
    public static func sizeText(_ bytes: Int64) -> String {
        let units = ["bytes", "KB", "MB", "GB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1000, unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        if unit == 0 { return "\(bytes) bytes" }
        return value < 10 ? String(format: "%.1f %@", value, units[unit]) : String(format: "%.0f %@", value, units[unit])
    }
}

#if canImport(ImageIO) && canImport(CoreGraphics)
/// ImageIO thumbnails: the longest side at most `maxPixels`, JPEG, stepping quality and size down until it fits.
public struct ImageIOThumbnailMaker: ThumbnailMaker {
    public let maxPixels: Int

    public init(maxPixels: Int = 256) {
        self.maxPixels = maxPixels
    }

    public func thumbnail(forFileAt url: URL, maxBytes: Int) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return thumbnail(from: source, maxBytes: maxBytes)
    }

    public func thumbnail(for data: Data, maxBytes: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return thumbnail(from: source, maxBytes: maxBytes)
    }

    private func thumbnail(from source: CGImageSource, maxBytes: Int) -> Data? {
        var pixels = maxPixels
        while pixels >= 32 {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: pixels,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            for quality in [0.75, 0.55, 0.35] {
                if let jpeg = Self.jpeg(image, quality: quality), jpeg.count <= maxBytes { return jpeg }
            }
            pixels /= 2
        }
        return nil
    }

    private static func jpeg(_ image: CGImage, quality: Double) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, "public.jpeg" as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
#endif

/// The thumbnail maker for this platform.
public func platformThumbnailMaker() -> any ThumbnailMaker {
    #if canImport(ImageIO) && canImport(CoreGraphics)
    return ImageIOThumbnailMaker()
    #else
    return NoThumbnails()
    #endif
}
