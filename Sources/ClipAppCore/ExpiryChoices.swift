import ClipSync

/// F14. The expiry choices the Mac menu and the iOS settings offer, and their labels.
public enum ExpiryChoices {
    /// nil keeps items forever.
    public static let presets: [Int?] = [nil, 1, 7, 30, 90]

    /// The presets, plus `current` when it isn't one (a hand-edited config.json), so the picker always
    /// shows what's actually set.
    public static func options(current: Int?) -> [Int?] {
        guard let current, current >= 1, !presets.contains(current) else { return presets }
        return [nil] + (presets.compactMap { $0 } + [min(current, SyncEngine.maxExpiryDays)]).sorted()
    }

    public static func label(_ days: Int?) -> String {
        switch days {
        case nil: Strings.expiryOff
        case 1: Strings.expiryOneDay
        case let days?: Strings.format(Strings.expiryDays, ["days": String(days)])
        }
    }
}
