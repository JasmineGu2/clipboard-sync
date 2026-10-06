import ClipCore
import Foundation

/// Runs one seeded simulation of the sync topology: N devices, one relay, a lossy network, crashes and bad clocks.
/// After `config.steps` the network heals, every device syncs until quiescent, and convergence is checked.
public func runSimulation(_ config: HarnessConfig) -> HarnessResult {
    var sim = Simulation(config: config)
    do throws(HarnessFailure) {
        try sim.run()
        return sim.result(failure: nil)
    } catch {
        return sim.result(failure: error.message)
    }
}

struct HarnessFailure: Error {
    var message: String
}

struct Simulation {
    let config: HarnessConfig
    private var rng: SplitMix64
    private var relay = SimRelay()
    private var devices: [SimDevice]
    /// Simulated true time in milliseconds. Device wall clocks are this plus their skew.
    private var time: UInt64 = 1_000_000
    private var step = 0
    private var stats = HarnessStats()
    private var trace: [String] = []
    private static let traceCapacity = 50

    /// Every op any device ever created, in creation order.
    private var allOps: [Op] = []
    /// Per device: the last timestamp it issued, across restarts (harness-side, survives crashes).
    private var lastIssued: [HLCTimestamp?]
    /// Per device: the highest persisted cursor seen so far.
    private var persistedCursorFloor: [Int64]
    private var issuedTimestamps: Set<HLCTimestamp> = []

    // Short labels for traces, and a stable order for random picks (dictionaries iterate in random order).
    private var itemLabels: [ItemID: Int] = [:]
    private var itemsByLabel: [ItemID] = []
    private var opLabels: [OpID: Int] = [:]
    private var deviceLabels: [DeviceID: String] = [:]

    private static let titles: [String?] = [nil, "a", "b", "c"]
    private static let tags = ["red", "green", "blue"]

    init(config: HarnessConfig) {
        self.config = config
        var rng = SplitMix64(seed: config.seed)
        let count = config.devices.map { min(5, max(2, $0)) } ?? Int.random(in: 2...5, using: &rng)
        var devices: [SimDevice] = []
        for i in 0..<count {
            let id = DeviceID(rng.uuid())
            let skew = Int64.random(in: -40...40, using: &rng)
            devices.append(SimDevice(index: i, id: id, skew: skew, mutation: config.mutation))
        }
        self.rng = rng
        self.devices = devices
        self.lastIssued = Array(repeating: nil, count: count)
        self.persistedCursorFloor = Array(repeating: 0, count: count)
        for device in devices { deviceLabels[device.id] = device.name }
    }

    // MARK: - Run

    mutating func run() throws(HarnessFailure) {
        for s in 0..<config.steps {
            step = s
            advanceTime()
            try stepOnce()
        }
        step = config.steps
        try heal()
        try checkFinal()
    }

    private mutating func advanceTime() {
        time += UInt64.random(in: 0...2, using: &rng)
        for i in devices.indices {
            devices[i].wall.millis = UInt64(max(0, Int64(time) + devices[i].skew))
        }
    }

    private mutating func randomDevice() -> Int { Int.random(in: 0..<devices.count, using: &rng) }

    private mutating func stepOnce() throws(HarnessFailure) {
        if rng.chance(config.crashRate) { try crash(randomDevice()) }
        if rng.chance(config.offlineToggleRate) {
            let d = randomDevice()
            devices[d].online.toggle()
            stats.offlineToggles += 1
            log("\(devices[d].name) \(devices[d].online ? "online" : "offline")")
        }
        if rng.chance(config.clockJumpRate) {
            let d = randomDevice()
            let delta = Int64.random(in: -40...15, using: &rng)
            devices[d].skew += delta
            devices[d].wall.millis = UInt64(max(0, Int64(time) + devices[d].skew))
            stats.clockJumps += 1
            log("\(devices[d].name) wall clock jumps \(delta)ms")
        }
        // Only draws from the RNG when expiry is on, so expiry-off seeds (seed 488 included) replay unchanged.
        if config.expiry != .off, rng.chance(config.expirySweepRate) { try expirySweep(randomDevice()) }
        // Same rule: no RNG draws unless blobs are on.
        if config.blobGC != .off, rng.chance(config.blobGCSweepRate) { blobGCSweep(randomDevice()) }
        let d = randomDevice()
        switch Int.random(in: 0..<100, using: &rng) {
        case 0..<40: try userAction(d)
        case 40..<68: try push(d, faulty: true)
        default: _ = try pull(d, limit: Int.random(in: 1...8, using: &rng), faulty: true)
        }
    }

    // MARK: - Events

    private mutating func userAction(_ d: Int) throws(HarnessFailure) {
        let known = devices[d].store.items.keys.compactMap { itemLabels[$0] }.sorted()
        let roll = Int.random(in: 0..<100, using: &rng)
        let item: ItemID
        let kind: OpKind
        if roll < 30 || known.isEmpty {
            item = ItemID(rng.uuid())
            itemLabels[item] = itemsByLabel.count
            itemsByLabel.append(item)
            let millis = devices[d].wall.millis
            let text = "t\(rng.next() % 1000)"
            let blob = config.blobGC == .off
                ? nil : BlobRef(id: BlobID(rng.uuid()), size: 1, sha256: Data(count: 32), contentType: nil)
            kind = .create(ItemContent(
                kind: blob == nil ? .text : .file,
                text: text,
                sourceDevice: devices[d].id,
                sourceDeviceName: devices[d].name,
                createdAt: Date(timeIntervalSince1970: TimeInterval(millis) / 1000),
                blob: blob
            ))
        } else {
            // Sometimes act on an item this device only just learned about.
            let recent = devices[d].recentItems
            if !recent.isEmpty, rng.chance(0.4), let pick = recent.randomElement(using: &rng) {
                item = pick
            } else {
                item = itemsByLabel[known[Int.random(in: 0..<known.count, using: &rng)]]
            }
            switch roll {
            case 30..<45: kind = .setPinned(Bool.random(using: &rng))
            case 45..<60: kind = .setTitle(Self.titles[Int.random(in: 0..<Self.titles.count, using: &rng)])
            case 60..<88:
                kind = .setTag(Self.tags[Int.random(in: 0..<Self.tags.count, using: &rng)], present: Bool.random(using: &rng))
            default: kind = .delete
            }
        }

        let op = devices[d].record(kind, item: item, opID: OpID(rng.uuid()))
        try noteIssued(op, by: d)
    }

    /// Bookkeeping and clock checks for an op a device just recorded.
    private mutating func noteIssued(_ op: Op, by d: Int, note: String = "") throws(HarnessFailure) {
        opLabels[op.id] = allOps.count
        allOps.append(op)
        stats.ops += 1
        log("\(devices[d].name) \(describe(op))\(note)")

        if config.checkClockMonotonic {
            if let last = lastIssued[d], !(last < op.timestamp) {
                throw fail("\(devices[d].name) issued \(describe(op.timestamp)), not after its previous \(describe(last))")
            }
            if !issuedTimestamps.insert(op.timestamp).inserted {
                throw fail("duplicate HLC timestamp \(describe(op.timestamp)) on \(label(op))")
            }
        }
        lastIssued[d] = op.timestamp
    }

    /// F14: the device expires its visible, unpinned items created before its wall clock minus the expiry age.
    /// Mirrors SyncEngine.expireItems, which records an ordinary `delete` op per item.
    private mutating func expirySweep(_ d: Int) throws(HarnessFailure) {
        let now = devices[d].wall.millis
        guard now > config.expiryAfterMillis else { return }
        // Same field as ClipDatabase.expiredItemIDs: the wall time of the item's create op.
        let cutoff = now - config.expiryAfterMillis
        let expired = devices[d].store.items.values
            .filter { $0.isVisible && !$0.pinned.value && !devices[d].hidden.contains($0.id) }
            .filter { ($0.createdBy?.wallMillis ?? .max) < cutoff }
            .compactMap { itemLabels[$0.id] }
            .sorted()
            .map { itemsByLabel[$0] }
        stats.expirySweeps += 1
        log("\(devices[d].name) expiry sweep: \(expired.count) item(s)")
        for item in expired {
            stats.expiredItems += 1
            switch config.expiry {
            case .off: preconditionFailure("expiry sweeps only run with expiry on")
            case .hideLocally:
                devices[d].hideLocally(item)
                log("\(devices[d].name) hides \(label(item)) locally")
            case .deleteOps:
                let op = devices[d].record(.delete, item: item, opID: OpID(rng.uuid()))
                try noteIssued(op, by: d, note: " (expired)")
            }
        }
    }

    /// Deletes blobs from the relay by the configured rule (see `BlobGCMode`).
    private mutating func blobGCSweep(_ d: Int) {
        guard devices[d].online else { return }
        let items = devices[d].store.items.values
        let before = relay.blobs.count
        switch config.blobGC {
        case .off: return
        case .deadItemsOnly:
            relay.blobs.subtract(items.filter(\.deleted).compactMap { $0.content?.blob?.id })
        case .unreferencedOnRelay:
            relay.blobs.formIntersection(items.filter(\.isVisible).compactMap { $0.content?.blob?.id })
        }
        stats.blobGCSweeps += 1
        stats.blobsCollected += before - relay.blobs.count
        log("\(devices[d].name) blob GC: \(before - relay.blobs.count) collected, \(relay.blobs.count) left on the relay")
    }

    private mutating func push(_ d: Int, faulty: Bool) throws(HarnessFailure) {
        guard devices[d].online, !devices[d].outbox.isEmpty else { return }
        let size = faulty ? Int.random(in: 1...6, using: &rng) : devices[d].outbox.count
        let batch = Array(devices[d].outbox.prefix(size))
        let names = batch.map(label).joined(separator: ",")
        stats.pushes += 1
        if faulty, rng.chance(config.pushRequestDropRate) {
            stats.pushRequestDrops += 1
            log("\(devices[d].name) push [\(names)] request LOST")
            return
        }
        let inserted = relay.append(batch)
        stats.duplicatePushes += batch.count - inserted
        if faulty, rng.chance(config.pushResponseDropRate) {
            stats.pushResponseDrops += 1
            log("\(devices[d].name) push [\(names)] stored (\(inserted) new), response LOST")
            return
        }
        devices[d].acknowledge(Set(batch.map(\.id)))
        log("\(devices[d].name) push [\(names)] ok (\(inserted) new, seq=\(relay.latestSeq))")
    }

    /// Returns the page (nil when offline or the response was dropped).
    private mutating func pull(_ d: Int, limit: Int, faulty: Bool) throws(HarnessFailure) -> SimRelay.Page? {
        guard devices[d].online else { return nil }
        let before = devices[d].cursor
        let page = relay.page(after: before, limit: limit)
        stats.pulls += 1
        if faulty, rng.chance(config.pullResponseDropRate) {
            stats.pullResponseDrops += 1
            log("\(devices[d].name) pull after=\(before) limit=\(limit) response LOST")
            return nil
        }
        devices[d].applyPage(page.entries)
        let device = devices[d]
        log("\(device.name) pull after=\(before) limit=\(limit) -> [\(page.entries.map { label($0.op) }.joined(separator: ","))]"
            + " cursor=\(device.cursor)\(page.hasMore ? " hasMore" : "")")

        if device.cursor < before {
            throw fail("\(device.name) cursor moved backwards: \(before) -> \(device.cursor)")
        }
        if device.disk.cursor < persistedCursorFloor[d] {
            throw fail("\(device.name) persisted cursor moved backwards: \(persistedCursorFloor[d]) -> \(device.disk.cursor)")
        }
        persistedCursorFloor[d] = device.disk.cursor
        if device.cursor > relay.latestSeq {
            throw fail("\(device.name) cursor \(device.cursor) is past the relay's latest seq \(relay.latestSeq)")
        }
        let seen = device.store.seenOps
        if let missing = page.entries.first(where: { !seen.contains($0.op.id) }) {
            throw fail("\(device.name) pulled \(label(missing.op)) but its replica doesn't contain it")
        }
        return page
    }

    private mutating func crash(_ d: Int) throws(HarnessFailure) {
        devices[d].restart(recovery: config.clockRecovery)
        stats.restarts += 1
        let device = devices[d]
        log("\(device.name) CRASH, restart at cursor=\(device.cursor) outbox=\(device.outbox.count)")

        if device.disk.cursor < persistedCursorFloor[d] {
            throw fail("\(device.name) restarted with cursor \(device.disk.cursor), below persisted \(persistedCursorFloor[d])")
        }
        // No lost data: every op this device created is on the relay or still in its persisted outbox.
        let outbox = Set(device.outbox.map(\.id))
        if let lost = allOps.first(where: {
            $0.timestamp.device == device.id && !relay.contains($0.id) && !outbox.contains($0.id)
        }) {
            throw fail("\(device.name) lost \(label(lost)) in a crash: not on the relay and not in its outbox")
        }
    }

    // MARK: - Heal and final checks

    private mutating func heal() throws(HarnessFailure) {
        log("--- network heals ---")
        for i in devices.indices { devices[i].online = true }
        var round = 0
        while true {
            round += 1
            if round > 50 { throw fail("no quiescence after 50 healed sync rounds") }
            var moved = false
            for i in devices.indices where !devices[i].outbox.isEmpty {
                try push(i, faulty: false)
                moved = true
            }
            for i in devices.indices {
                while let page = try pull(i, limit: 50, faulty: false), !page.entries.isEmpty {
                    moved = true
                    if !page.hasMore { break }
                }
            }
            if !moved { break }
        }
        stats.healRounds = round
    }

    private mutating func checkFinal() throws(HarnessFailure) {
        // (4) The relay never stores an op ID twice.
        let logIDs = relay.log.map(\.op.id)
        if Set(logIDs).count != logIDs.count {
            throw fail("relay log has duplicate op IDs (\(logIDs.count) entries, \(Set(logIDs).count) distinct)")
        }
        // (3) No op created by any device is missing from the relay.
        if let lost = allOps.first(where: { !relay.contains($0.id) }) {
            throw fail("\(label(lost)) (by \(deviceLabels[lost.timestamp.device] ?? "?")) never reached the relay")
        }
        if relay.log.count != allOps.count {
            throw fail("relay has \(relay.log.count) ops but devices created \(allOps.count)")
        }
        for device in devices where !device.outbox.isEmpty {
            throw fail("\(device.name) still has \(device.outbox.count) unsent ops after healing")
        }
        // (1) All replicas are equal.
        for device in devices.dropFirst() where device.store != devices[0].store {
            throw fail("replicas diverged: \(diff(devices[0].name, devices[0].store.items, device.name, device.store.items))")
        }
        // (5) Every device shows the same items. Equal replicas imply this unless a device hides items
        // outside the op log, which is what `ExpiryMode.hideLocally` does.
        for device in devices.dropFirst() where device.shownItems != devices[0].shownItems {
            let onlyFirst = devices[0].shownItems.subtracting(device.shownItems).map(label).sorted()
            let onlyThis = device.shownItems.subtracting(devices[0].shownItems).map(label).sorted()
            throw fail("devices show different items: only \(devices[0].name) shows \(onlyFirst), "
                + "only \(device.name) shows \(onlyThis)")
        }
        // (6) Blobs: no visible item lost its blob to garbage collection, and once every device has swept after
        // healing, the relay holds exactly the visible items' blobs (nothing leaked).
        if config.blobGC != .off {
            let visible = devices[0].store.items.values.filter(\.isVisible)
            if let lost = visible.first(where: { $0.content?.blob.map { !relay.blobs.contains($0.id) } ?? false }) {
                throw fail("visible item \(label(lost.id))'s blob was garbage-collected from the relay")
            }
            for i in devices.indices { blobGCSweep(i) }
            let wanted = Set(visible.compactMap { $0.content?.blob?.id })
            if relay.blobs != wanted {
                throw fail("after a final sweep the relay holds \(relay.blobs.count) blobs, visible items use \(wanted.count)")
            }
        }
        // (2) Each equals ClipCore's Replica built from every op, in a random order.
        var shuffled = allOps
        shuffled.shuffle(using: &rng)
        var reference = Replica()
        for op in shuffled { reference.apply(op) }
        for device in devices {
            if device.store.seenOps != reference.seenOps {
                throw fail("\(device.name) has seen \(device.store.seenOps.count) ops, reference \(reference.seenOps.count)")
            }
            if device.store.items != reference.items {
                throw fail("\(device.name) differs from the reference replica: "
                    + diff(device.name, device.store.items, "reference", reference.items))
            }
        }
    }

    // MARK: - Reporting

    func result(failure: String?) -> HarnessResult {
        let header = "seed \(config.seed) (devices \(devices.count), steps \(config.steps), mutation \(config.mutation.rawValue), "
            + "clock recovery \(config.clockRecovery.rawValue)) failed at step \(step)"
        return HarnessResult(
            seed: config.seed,
            devices: devices.count,
            converged: failure == nil,
            failure: failure.map { "\(header): \($0)\nlast \(trace.count) events:\n" + trace.joined(separator: "\n") },
            trace: trace,
            stats: stats,
            finalItems: devices[0].store.items
        )
    }

    private func fail(_ message: String) -> HarnessFailure { HarnessFailure(message: message) }

    private mutating func log(_ event: String) {
        trace.append("#\(step) t=\(time - 1_000_000) \(event)")
        if trace.count > Self.traceCapacity { trace.removeFirst(trace.count - Self.traceCapacity) }
    }

    private func label(_ op: Op) -> String { "o\(opLabels[op.id] ?? -1)" }
    private func label(_ item: ItemID) -> String { "i\(itemLabels[item] ?? -1)" }

    private func describe(_ ts: HLCTimestamp) -> String {
        let wall = Int64(bitPattern: ts.wallMillis) - 1_000_000
        return "(\(wall),\(ts.counter),\(deviceLabels[ts.device] ?? "?"))"
    }

    private func describe(_ op: Op) -> String {
        let what: String
        switch op.kind {
        case .create(let content): what = "create '\(content.text)'"
        case .setPinned(let v): what = v ? "pin" : "unpin"
        case .setTitle(let v): what = "title=\(v.map { "'\($0)'" } ?? "nil")"
        case .setTag(let name, let present): what = "tag \(present ? "+" : "-")\(name)"
        case .delete: what = "delete"
        }
        return "\(label(op)) \(what) \(label(op.itemID)) @\(describe(op.timestamp))"
    }

    private func describe(_ state: ItemState?) -> String {
        guard let s = state else { return "absent" }
        func reg<V: Hashable & Codable & Sendable>(_ r: LWW<V>) -> String { "\(r.value)@\(r.timestamp.map { describe($0) } ?? "-")" }
        let tags = s.tags.keys.sorted().compactMap { k in s.tags[k].map { "\(k)=\(reg($0))" } }.joined(separator: " ")
        return "{content=\(s.content.map { "'\($0.text)'" } ?? "nil")@\(s.createdBy.map { describe($0) } ?? "-")"
            + " deleted=\(s.deleted) pinned=\(reg(s.pinned)) title=\(reg(s.title)) tags=[\(tags)]}"
    }

    /// Describes the first item (in creation order) that differs between two states.
    private func diff(_ aName: String, _ a: [ItemID: ItemState], _ bName: String, _ b: [ItemID: ItemState]) -> String {
        let ids = Set(a.keys).union(b.keys).sorted { (itemLabels[$0] ?? .max) < (itemLabels[$1] ?? .max) }
        guard let id = ids.first(where: { a[$0] != b[$0] }) else { return "items equal, seen-op sets differ" }
        // Every op on that item, in timestamp order, flagging timestamps that were issued more than once.
        let ops = allOps.filter { $0.itemID == id }.sorted { $0.timestamp < $1.timestamp }
        var counts: [HLCTimestamp: Int] = [:]
        for op in ops { counts[op.timestamp, default: 0] += 1 }
        let history = ops.map { op in
            "  \(describe(op))" + ((counts[op.timestamp] ?? 0) > 1 ? "   <-- timestamp reused" : "")
        }
        return "\(label(id)): \(aName)=\(describe(a[id])) \(bName)=\(describe(b[id]))\nops on \(label(id)):\n"
            + history.joined(separator: "\n")
    }
}
