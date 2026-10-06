import ClipCore
import ClipCrypto
import ClipStore
import ClipWire
import Foundation

// F16: direct device-to-device sync over the tailnet while the relay is unreachable. See docs/design.md §7 and
// docs/decisions.md (2026-10-05).
//
// Every device's local op log is append-only and numbered (`ops.seq`), just like the relay's. So a device that can
// listen acts as a small relay for the others: a peer pulls its log after a cursor it keeps for that device, and
// pushes its own log after a second cursor. Ops are the same OpCipher envelopes as on the relay, inside a request
// sealed with HPKE AuthPSK (ClipCrypto `PeerChannel`): only a device in this device's (cached, sealed) device list,
// holding the current vault key, can make one, and only this device can open it. Ops received directly are queued
// for push, so the relay catches up through the normal push path when it's back. Applying an op twice is a no-op
// (N13), so overlaps between relay and peer delivery cost nothing but bytes.

/// How this engine syncs directly with other devices.
public struct PeerSetup: Sendable {
    /// Dials devices that listen.
    public var dialer: any PeerDialer
    /// "<IPv4>:<port>" this device listens on, advertised (sealed) in its device record. nil: dial out only
    /// (the iPhone, which can't keep a listener running in the background).
    public var listenAddress: String?

    public init(dialer: any PeerDialer, listenAddress: String? = nil) {
        self.dialer = dialer
        self.listenAddress = listenAddress
    }
}

/// How this device is syncing right now.
public enum SyncPath: Equatable, Sendable {
    /// Through the relay, as normal.
    case relay
    /// The relay is unreachable; exchanged directly with this many devices in the last half minute.
    case direct(peers: Int)
    /// Neither the relay nor any other device answered.
    case offline
}

/// Another device as far as direct sync goes: from the device list, opened under the current vault key.
public struct PeerInfo: Equatable, Sendable {
    public let id: String
    public let name: String
    public let publicKey: Data
    /// nil when it doesn't listen; it can still dial this device.
    public let address: String?
}

/// This device's position in another device's log, and in its own log as sent to that device.
struct PeerCursor: Codable, Equatable {
    /// The other device's log ID these cursors refer to.
    var logID: String?
    /// Its log has been pulled through this local seq of its.
    var pulled: Int64 = 0
    /// This device's log has been pushed to it through this local seq of ours.
    var pushed: Int64 = 0
}

/// Encapsulated keys of requests already answered, so a replayed request is refused.
struct PeerReplayCache {
    private var seen: [Data: Int64] = [:]
    static let capacity = 4096

    /// True the first time `id` is seen within `ttlMillis`.
    mutating func admit(_ id: Data, nowMillis: Int64, ttlMillis: Int64) -> Bool {
        seen = seen.filter { $0.value > nowMillis }
        guard seen[id] == nil else { return false }
        if seen.count >= Self.capacity, let oldest = seen.min(by: { $0.value < $1.value })?.key {
            seen[oldest] = nil
        }
        seen[id] = nowMillis + ttlMillis
        return true
    }
}

public enum PeerSyncError: Error, Equatable, Sendable {
    /// The other device answered with a refusal.
    case refused(PeerRefusal)
    /// Its answer didn't open or decode.
    case badResponse
}

extension SyncEngine {
    static let peerDirectoryKey = "peer_directory"
    static func peerCursorKey(_ deviceID: String) -> String { "peer_cursor.\(deviceID)" }
    /// How often devices are dialed while the relay is unreachable (and right after each local change).
    static let peerInterval: Duration = .seconds(2)
    /// A direct exchange counts toward `syncPath` this long.
    static let peerContactWindow: TimeInterval = 30
    /// The cached device list is refreshed this often while the relay is reachable, so a newly paired device can
    /// dial this one within about a minute (sooner if it already tried: see `answer`).
    static let peerDirectoryMaxAge: TimeInterval = 60
    static let peerDialTimeout: Duration = .seconds(10)
    static let peerUnknownRefreshAge: TimeInterval = 10
    /// Request/response rounds per device per pass; a big first exchange continues in the next pass.
    static let peerRoundsPerPass = 40

    /// Turns on direct sync. Call before `run()`. With a listen address, this device's record is registered again
    /// with it, so other devices can dial it.
    public func enablePeerSync(_ setup: PeerSetup) {
        peerSetup = setup
        registeredUnder = nil
        peerDirectoryRefreshedAt = nil
    }

    public var syncPath: SyncPath {
        if status == .revoked { return .offline }
        if relayReachable { return .relay }
        let cutoff = now().addingTimeInterval(-Self.peerContactWindow)
        let recent = peerContacts.values.filter { $0 >= cutoff }.count
        return recent > 0 ? .direct(peers: recent) : .offline
    }

    /// The other devices in the cached device list that open under the current vault key. Opened once per list and
    /// key (`openedPeers`), since every incoming request looks its sender up here.
    public func peers() -> [PeerInfo] {
        // Keyed by the stored list too: another process on the same database (`clipctl devices` beside a running
        // `watch`) may have cached a newer one.
        guard let json = try? db.meta(Self.peerDirectoryKey) else { return [] }
        if let cached = openedPeers, cached.key == vaultKey, cached.json == json { return cached.peers }
        let peers = openPeerDirectory(json)
        openedPeers = (vaultKey, json, peers)
        return peers
    }

    private func openPeerDirectory(_ json: String) -> [PeerInfo] {
        guard let records = try? JSONDecoder().decode([DeviceRecord].self, from: Data(json.utf8))
        else { return [] }
        return opened(records, quiet: true)
            .filter { !$0.isThisDevice }
            .map { PeerInfo(id: $0.id, name: $0.name, publicKey: $0.publicKey, address: $0.peerAddress) }
    }

    /// Keeps the device list as the relay sent it: still sealed (names and addresses under the vault key), so the
    /// cache says nothing the relay didn't already see, and it stops opening after a revoke changes the key.
    func cachePeerDirectory(_ records: [DeviceRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? db.setMeta(Self.peerDirectoryKey, String(decoding: data, as: UTF8.self))
        peerDirectoryRefreshedAt = now()
        openedPeers = nil
    }

    /// After a successful relay sync: refreshes the cached device list when it's old. Failures only log.
    func refreshPeerDirectoryIfNeeded() async {
        guard peerSetup != nil, membership != nil else { return }
        if let at = peerDirectoryRefreshedAt {
            let age = now().timeIntervalSince(at)
            // Sooner when an unknown device knocked since (it may have just paired), but not more than every 10 s:
            // anyone on the tailnet can knock.
            let knocked = peerUnknownSince.map { $0 > at } ?? false
            if age < (knocked ? Self.peerUnknownRefreshAge : Self.peerDirectoryMaxAge) { return }
        }
        do {
            cachePeerDirectory(try await transport.listDevices())
        } catch {
            log("couldn't refresh the device list for direct sync: \(error)")
        }
    }

    static func meansRelayUnreachable(_ error: any Error) -> Bool {
        switch error {
        case TransportError.network: return true
        case TransportError.server(let status): return status >= 500
        default: return false
        }
    }

    func noteRelayUnreachable() {
        let was = relayReachable
        relayReachable = false
        if was { wakePeers() }
    }

    // MARK: Dialing out

    /// One pass over every device that listens: push what it hasn't had from here, pull what it has. Returns how
    /// many answered. `run()` calls this every couple of seconds while the relay is unreachable; tests and clipctl
    /// can call it directly. Passes run one at a time.
    @discardableResult
    public func syncWithPeers() async -> Int {
        while let running = peerRoundTask { _ = await running.value }
        let task = Task { await self.performPeerPass() }
        peerRoundTask = task
        defer { peerRoundTask = nil }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func performPeerPass() async -> Int {
        guard let setup = peerSetup, membership != nil, status != .revoked else { return 0 }
        var reached = 0
        for peer in peers() where peer.address != nil {
            if Task.isCancelled { break }
            do {
                try await exchange(with: peer, dialer: setup.dialer)
                reached += 1
                if peerErrors.removeValue(forKey: peer.id) != nil { log("direct sync with \(peer.name) works again") }
            } catch {
                let message = String(describing: error)
                if peerErrors[peer.id] != message {
                    log("direct sync with \(peer.name) failed: \(message)")
                    peerErrors[peer.id] = message
                }
            }
        }
        return reached
    }

    /// Exchanges with one device until neither side has more, or `peerRoundsPerPass` rounds.
    func exchange(with peer: PeerInfo, dialer: any PeerDialer) async throws {
        guard let membership, let address = peer.address, let (host, port) = PeerAddress.parse(address),
              isDialable(host)
        else {
            throw PeerTransportError.unreachable(peer.address ?? "no address")
        }
        let key = Self.peerCursorKey(peer.id)
        var cursor = (try? db.meta(key)).flatMap { $0 }.flatMap {
            try? JSONDecoder().decode(PeerCursor.self, from: Data($0.utf8))
        } ?? PeerCursor()

        for _ in 0..<Self.peerRoundsPerPass {
            try Task.checkCancellation()
            let vaultKey = self.vaultKey
            // Push: this device's log after the push cursor, as OpCipher envelopes carrying our local seq.
            let rows = try db.ops(afterSeq: cursor.pushed, limit: PeerLimits.maxEnvelopes)
            var envelopes: [Envelope] = []
            var bytes = 0
            var pushedThrough = cursor.pushed
            for row in rows {
                var envelope = try cipher.seal(row.op, device: device)
                envelope.seq = row.seq
                bytes += envelope.ciphertext.count + 200
                if !envelopes.isEmpty, bytes > PeerLimits.maxEnvelopeBytes { break }
                envelopes.append(envelope)
                pushedThrough = row.seq
            }
            let morePush = envelopes.count < rows.count || rows.count == PeerLimits.maxEnvelopes

            let request = PeerRequest(
                sentAtMillis: Int64(Self.millis(now())), envelopes: envelopes, logID: cursor.logID,
                after: cursor.pulled, limit: PeerLimits.maxEnvelopes)
            let sealed = try PeerChannel.sealRequest(
                try JSONEncoder().encode(request), from: deviceIDString, to: peer.id,
                deviceKey: membership.deviceKey, recipient: peer.publicKey, vaultKey: vaultKey)
            let frame = PeerRequestFrame(from: deviceIDString, to: peer.id, enc: sealed.encapsulatedKey, sealed: sealed.ciphertext)
            let answer = try await dialer.exchange(
                host: host, port: port, request: try JSONEncoder().encode(frame), timeout: Self.peerDialTimeout)

            guard let responseFrame = try? JSONDecoder().decode(PeerResponseFrame.self, from: answer) else {
                throw PeerSyncError.badResponse
            }
            if let refusal = responseFrame.error { throw PeerSyncError.refused(refusal) }
            guard let body = responseFrame.sealed, let plaintext = try? sealed.responseKey.open(body),
                  let response = try? JSONDecoder().decode(PeerResponse.self, from: plaintext),
                  response.envelopes.count <= PeerLimits.maxEnvelopes,
                  response.envelopes.allSatisfy({ $0.ciphertext.count <= WireLimits.maxCiphertextBytes })
            else { throw PeerSyncError.badResponse }
            // A revoke swapped the key while this waited: drop the answer; the next pass uses the new key.
            guard self.vaultKey == vaultKey else { return }

            // Where the responder read from: our cursor if the log is the one it belongs to, else 0.
            let sameLog = cursor.logID == response.logID
            let readFrom = sameLog ? cursor.pulled : 0
            // Seqs must climb from there and stay within its log, or one bad page could park our cursor anywhere.
            var previous = readFrom
            for envelope in response.envelopes {
                guard let seq = envelope.seq, seq > previous, seq <= response.latestSeq else {
                    throw PeerSyncError.badResponse
                }
                previous = seq
            }

            var next = cursor
            var restarted = false
            if let known = cursor.logID, known != response.logID {
                // Its database is new: our cursor into its log means nothing, and it lost what we sent. Start over.
                log("\(peer.name)'s log changed; exchanging everything again")
                next = PeerCursor(logID: response.logID, pulled: 0, pushed: 0)
                restarted = true
            } else if sameLog, cursor.pulled > response.latestSeq {
                // Same log ID but shorter: restored from a backup. Its new ops would sit below our cursor, and it may
                // have lost what we pushed. Start over (duplicates are harmless).
                log("\(peer.name)'s log went back to seq \(response.latestSeq); exchanging everything again")
                next = PeerCursor(logID: response.logID, pulled: 0, pushed: 0)
                restarted = true
            } else {
                next.logID = response.logID
                next.pushed = pushedThrough
            }
            // The page counts unless it was read from a cursor past a restored log (then it's empty anyway).
            if let last = response.envelopes.last?.seq, !(restarted && sameLog) { next.pulled = max(next.pulled, last) }
            let ops = openPeerEnvelopes(response.envelopes, from: peer.name)
            try storePeerOps(ops, meta: [key: String(decoding: try JSONEncoder().encode(next), as: UTF8.self)])
            cursor = next
            peerContacts[peer.id] = now()
            if !restarted, !response.hasMore, !morePush { return }
        }
    }

    /// Only Tailscale addresses: another member chose this one, and it mustn't point us at the LAN or our own
    /// loopback. Loopback is allowed only when this device itself listens on loopback (tests, a one-machine setup).
    func isDialable(_ host: String) -> Bool {
        if PeerAddress.isTailnet(host) { return true }
        guard PeerAddress.isLoopback(host), let own = peerSetup?.listenAddress.flatMap(PeerAddress.parse) else { return false }
        return PeerAddress.isLoopback(own.host)
    }

    // MARK: Answering

    /// The listener's handler: answers one request frame from another device. Never throws; a refusal is an
    /// error frame in the clear.
    public func handlePeerRequest(_ body: Data) async -> Data {
        let frame: PeerResponseFrame
        do {
            frame = try answer(body)
        } catch let refusal as PeerRefusal {
            frame = PeerResponseFrame(error: refusal)
        } catch {
            log("direct sync request failed: \(error)")
            frame = PeerResponseFrame(error: .badRequest)
        }
        return (try? JSONEncoder().encode(frame)) ?? Data()
    }

    private func answer(_ body: Data) throws -> PeerResponseFrame {
        guard let membership, peerSetup != nil, status != .revoked else { throw PeerRefusal.unavailable }
        guard let frame = try? JSONDecoder().decode(PeerRequestFrame.self, from: body),
              frame.version == PeerLimits.version, frame.to == deviceIDString, frame.from != deviceIDString
        else { throw PeerRefusal.badRequest }
        // Only devices in this device's list, under the current vault key. A revoked device isn't in a list sealed
        // under the new key, and can't make a request under it anyway (the PSK comes from the vault key).
        guard let peer = peers().first(where: { $0.id == frame.from }) else {
            // Maybe it paired after our list was cached: re-read the list sooner (rate-limited, see refresh).
            peerUnknownSince = now()
            throw PeerRefusal.unknownDevice
        }
        let opened: (plaintext: Data, responseKey: PeerChannel.ResponseKey)
        do {
            opened = try PeerChannel.openRequest(
                encapsulatedKey: frame.enc, ciphertext: frame.sealed, from: frame.from, to: frame.to,
                deviceKey: membership.deviceKey, sender: peer.publicKey, vaultKey: vaultKey)
        } catch {
            throw PeerRefusal.unauthenticated
        }
        guard let request = try? JSONDecoder().decode(PeerRequest.self, from: opened.plaintext),
              request.envelopes.count <= PeerLimits.maxEnvelopes,
              request.envelopes.allSatisfy({ $0.ciphertext.count <= WireLimits.maxCiphertextBytes })
        else { throw PeerRefusal.badRequest }
        // Replay: the request must be recent by our clock, and its ephemeral key new. Checked only after it
        // authenticated, so strangers can't fill the cache.
        let nowMillis = Int64(clamping: Self.millis(now()))
        // Overflow-safe: sentAtMillis is the sender's to choose.
        let (skew, overflow) = nowMillis.subtractingReportingOverflow(request.sentAtMillis)
        guard !overflow, skew.magnitude <= UInt64(PeerLimits.clockWindowMillis) else { throw PeerRefusal.clockSkew }
        guard peerReplay.admit(frame.enc, nowMillis: nowMillis, ttlMillis: 2 * PeerLimits.clockWindowMillis)
        else { throw PeerRefusal.replay }

        try storePeerOps(openPeerEnvelopes(request.envelopes, from: peer.name), meta: [:])

        let logID = try db.logID()
        let after = request.logID == logID ? max(0, request.after) : 0
        let limit = min(max(1, request.limit), PeerLimits.maxEnvelopes)
        let rows = try db.ops(afterSeq: after, limit: limit)
        var envelopes: [Envelope] = []
        var bytes = 0
        for row in rows {
            var envelope = try cipher.seal(row.op, device: device)
            envelope.seq = row.seq
            bytes += envelope.ciphertext.count + 200
            if !envelopes.isEmpty, bytes > PeerLimits.maxEnvelopeBytes { break }
            envelopes.append(envelope)
        }
        var hasMore = envelopes.count < rows.count
        if !hasMore, rows.count == limit, let last = rows.last {
            hasMore = !(try db.ops(afterSeq: last.seq, limit: 1)).isEmpty
        }
        let response = PeerResponse(logID: logID, envelopes: envelopes, hasMore: hasMore, latestSeq: try db.latestOpSeq())
        let sealed = try opened.responseKey.seal(try JSONEncoder().encode(response))
        peerContacts[peer.id] = now()
        return PeerResponseFrame(sealed: sealed)
    }

    /// Opens envelopes from another device. One that doesn't open is skipped and recorded, as from the relay.
    private func openPeerEnvelopes(_ envelopes: [Envelope], from name: String) -> [Op] {
        var ops: [Op] = []
        var undecryptable: [String] = []
        for envelope in envelopes {
            do {
                ops.append(try cipher.open(envelope))
            } catch {
                undecryptable.append(envelope.opID)
                log("skipping an undecryptable op \(envelope.opID) from \(name): \(error)")
            }
        }
        if !undecryptable.isEmpty { try? recordUndecryptable(undecryptable) }
        return ops
    }

    // MARK: Background work

    /// Beside `run()`'s relay loop: while the relay is unreachable, a pass every `peerInterval` and right after
    /// each local change. While it's reachable, nothing.
    func runPeerWork() async {
        while !Task.isCancelled {
            if !relayReachable, status != .revoked { await syncWithPeers() }
            await waitForPeerWork(timeout: relayReachable ? .seconds(3600) : Self.peerInterval)
        }
    }

    func wakePeers() {
        peerWorkPending = true
        peerWaiter?.resume()
        peerWaiter = nil
    }

    private func waitForPeerWork(timeout: Duration) async {
        if peerWorkPending {
            peerWorkPending = false
            return
        }
        let timer = Task { [weak self] in
            guard (try? await Task.sleep(for: timeout)) != nil else { return }
            await self?.wakePeers()
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if Task.isCancelled {
                    continuation.resume()
                    return
                }
                peerWaiter = continuation
            }
        } onCancel: {
            Task { await self.wakePeers() }
        }
        timer.cancel()
        peerWorkPending = false
    }
}

extension PeerRefusal: Error {}
