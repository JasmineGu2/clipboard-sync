import ClipSync
import ClipWire
import Foundation
import XCTest
@testable import ClipPeerSocket

/// F16: the real socket layer, on loopback.
final class SocketPeerTests: XCTestCase {
    func testOneFrameEachWayOverLoopback() async throws {
        let listener = try SocketPeerListener(host: "127.0.0.1", port: 0)
        defer { listener.stop() }
        try listener.start { request in Data("echo:".utf8) + request }
        let (host, port) = try XCTUnwrap(PeerAddress.parse(listener.boundAddress))
        XCTAssertEqual(host, "127.0.0.1")
        XCTAssertGreaterThan(port, 0)
        let dialer = SocketPeerDialer()
        let answer = try await dialer.exchange(host: host, port: port, request: Data("hi".utf8), timeout: .seconds(5))
        XCTAssertEqual(String(decoding: answer, as: UTF8.self), "echo:hi")

        // A large frame (2 MiB) and several at once.
        let big = Data(repeating: 7, count: 2 << 20)
        try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<12 {
                group.addTask { try await dialer.exchange(host: host, port: port, request: big, timeout: .seconds(10)).count }
            }
            for try await count in group { XCTAssertEqual(count, big.count + 5) }
        }
    }

    func testAnOversizedLengthPrefixIsRefusedWithoutReadingIt() async throws {
        let listener = try SocketPeerListener(host: "127.0.0.1", port: 0)
        defer { listener.stop() }
        try listener.start { _ in
            XCTFail("the handler ran for an oversized frame")
            return Data()
        }
        let (host, port) = try XCTUnwrap(PeerAddress.parse(listener.boundAddress))
        let s = Sock.tcp()
        defer { Sock.close(s) }
        Sock.noSigPipe(s)
        XCTAssertTrue(Sock.connect(s, try XCTUnwrap(Sock.address(host: host, port: port)), timeoutMillis: 2000))
        let length = UInt32(PeerLimits.maxFrameBytes + 1)
        let deadline = Date().addingTimeInterval(5)
        XCTAssertTrue(Sock.writeAll(s, Data([UInt8(length >> 24), UInt8((length >> 16) & 0xff), UInt8((length >> 8) & 0xff), UInt8(length & 0xff)]), until: deadline))
        XCTAssertNil(Sock.readFrame(s, until: deadline), "the listener closes the connection")
    }

    /// A peer that trickles bytes is cut off at the connection deadline, not kept alive by each byte.
    func testASlowSenderIsCutOffAtTheDeadline() throws {
        let listener = try SocketPeerListener(host: "127.0.0.1", port: 0, ioTimeout: 1)
        defer { listener.stop() }
        try listener.start { _ in Data("never".utf8) }
        let (host, port) = try XCTUnwrap(PeerAddress.parse(listener.boundAddress))
        let s = Sock.tcp()
        defer { Sock.close(s) }
        Sock.noSigPipe(s)
        XCTAssertTrue(Sock.connect(s, try XCTUnwrap(Sock.address(host: host, port: port)), timeoutMillis: 2000))
        let started = Date()
        for byte: UInt8 in [0, 0, 0, 10, 1, 2, 3] {  // announces 10 bytes, sends 3, one every 0.3 s
            _ = Sock.writeAll(s, Data([byte]), until: Date().addingTimeInterval(1))
            Thread.sleep(forTimeInterval: 0.3)
        }
        XCTAssertNil(Sock.readFrame(s, until: Date().addingTimeInterval(3)))
        XCTAssertLessThan(Date().timeIntervalSince(started), 4.5)
    }

    func testAStoppedListenerFreesItsPortForANewOne() async throws {
        let first = try SocketPeerListener(host: "127.0.0.1", port: 0)
        try first.start { _ in Data("first".utf8) }
        let (host, port) = try XCTUnwrap(PeerAddress.parse(first.boundAddress))
        first.stop()
        try await Task.sleep(for: .milliseconds(500))
        let second = try SocketPeerListener(host: host, port: port)
        defer { second.stop() }
        try second.start { _ in Data("second".utf8) }
        let answer = try await SocketPeerDialer().exchange(host: host, port: port, request: Data("x".utf8), timeout: .seconds(3))
        XCTAssertEqual(String(decoding: answer, as: UTF8.self), "second")
    }

    func testDialingNothingFailsFast() async throws {
        let listener = try SocketPeerListener(host: "127.0.0.1", port: 0)
        let (host, port) = try XCTUnwrap(PeerAddress.parse(listener.boundAddress))
        listener.stop()
        let started = Date()
        do {
            _ = try await SocketPeerDialer().exchange(host: host, port: port, request: Data("x".utf8), timeout: .seconds(3))
            XCTFail("connected to a stopped listener")
        } catch PeerTransportError.unreachable {}
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    func testATakenPortFailsAtBind() throws {
        let first = try SocketPeerListener(host: "127.0.0.1", port: 0)
        defer { first.stop() }
        let port = try XCTUnwrap(PeerAddress.parse(first.boundAddress)).port
        XCTAssertThrowsError(try SocketPeerListener(host: "127.0.0.1", port: port))
    }

    func testAddressParsing() {
        XCTAssertEqual(PeerAddress.parse("100.101.102.103:8790")?.port, 8790)
        XCTAssertNil(PeerAddress.parse("example.com:80"))
        XCTAssertNil(PeerAddress.parse("100.1.2.3:0"))
        XCTAssertNil(PeerAddress.parse("100.1.2.300:80"))
        XCTAssertNil(PeerAddress.parse("100.1.2.3"))
        XCTAssertTrue(PeerAddress.isTailnet("100.64.0.1"))
        XCTAssertTrue(PeerAddress.isTailnet("100.127.255.255"))
        XCTAssertFalse(PeerAddress.isTailnet("100.128.0.1"))
        XCTAssertFalse(PeerAddress.isTailnet("192.168.1.2"))
    }
}
