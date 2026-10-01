import Foundation

/// The one JSON encoding for ops and item state, used for encryption (ClipCrypto) and storage (ClipStore).
///
/// Dates are whole milliseconds since 1970, as an integer. Text formats round-trip through floating point,
/// so re-encoding a decoded date could drift by 1 ms. Replicas that stored the same op once vs. twice then
/// differed (caught by SyncEngineTests.testRelayResetResetsCursorAndRepulls, intermittently). Integer
/// milliseconds are a fixed point: decode then encode gives back the same number.
public enum ClipCoding {
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(millis(date))
        }
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let ms = try? container.decode(Int64.self) {
                return Date(timeIntervalSince1970: Double(ms) / 1000)
            }
            // Pre-2026-10-01 data stored ISO-8601 strings.
            let string = try container.decode(String.self)
            if let date = try? isoWithFraction.parse(string) { return date }
            if let date = try? isoPlain.parse(string) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "bad date \(string)")
        }
        return decoder
    }

    /// Rounds to the millisecond the encoder will store, so in-memory values match decoded ones.
    public static func normalized(_ date: Date) -> Date {
        Date(timeIntervalSince1970: Double(millis(date)) / 1000)
    }

    static func millis(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    private static let isoWithFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let isoPlain = Date.ISO8601FormatStyle()
}
