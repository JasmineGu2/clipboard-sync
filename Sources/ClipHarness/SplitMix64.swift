import Foundation

/// Small seeded RNG. Every random choice in the harness comes from one of these, so a seed replays exactly.
public struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A UUID drawn from the stream (IDs must be seeded too, or runs aren't reproducible).
    public mutating func uuid() -> UUID {
        let a = next(), b = next()
        func byte(_ x: UInt64, _ i: UInt64) -> UInt8 { UInt8(truncatingIfNeeded: x >> (i * 8)) }
        return UUID(uuid: (
            byte(a, 0), byte(a, 1), byte(a, 2), byte(a, 3), byte(a, 4), byte(a, 5), byte(a, 6), byte(a, 7),
            byte(b, 0), byte(b, 1), byte(b, 2), byte(b, 3), byte(b, 4), byte(b, 5), byte(b, 6), byte(b, 7)
        ))
    }

    /// True with probability `p`.
    mutating func chance(_ p: Double) -> Bool {
        p > 0 && Double.random(in: 0..<1, using: &self) < p
    }
}
