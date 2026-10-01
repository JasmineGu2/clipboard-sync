import ClipWire
import Foundation
import XCTest
@testable import ClipSync
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class HTTPTransportTests: XCTestCase {
    func url(_ string: String) throws -> URL { try XCTUnwrap(URL(string: string)) }
    func makeBuilder(token: String? = "abc123") throws -> RelayRequestBuilder {
        RelayRequestBuilder(baseURL: try url("http://relay.tailnet:8080"), token: token)
    }

    func testPushRequest() throws {
        let envelope = Envelope(opID: "op", itemID: "item", deviceID: "dev", ciphertext: Data([1, 2, 3]))
        let request = try makeBuilder().push(PushRequest(envelopes: [envelope]))
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "http://relay.tailnet:8080/v1/ops")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer abc123")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(request.httpBody)
        let decoded = try JSONDecoder().decode(PushRequest.self, from: body)
        XCTAssertEqual(decoded.envelopes, [envelope])
        // Default Data strategy: base64.
        XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("\"AQID\""))
    }

    func testPullRequestHasQueryAndLongPollTimeout() throws {
        let request = try makeBuilder().pull(after: 42, limit: 500, wait: 25)
        XCTAssertEqual(request.httpMethod, "GET")
        let url = try XCTUnwrap(request.url)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.path, "/v1/ops")
        XCTAssertEqual(
            components.queryItems,
            [URLQueryItem(name: "after", value: "42"), URLQueryItem(name: "limit", value: "500"),
             URLQueryItem(name: "wait", value: "25")])
        XCTAssertEqual(request.timeoutInterval, 35)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer abc123")
    }

    func testBaseURLWithPathPrefix() throws {
        let prefixed = RelayRequestBuilder(baseURL: try url("http://host/relay/"), token: nil)
        XCTAssertEqual(prefixed.pull(after: 0, limit: 1, wait: 0).url?.absoluteString,
                       "http://host/relay/v1/ops?after=0&limit=1&wait=0")
    }

    func testNoTokenMeansNoAuthorizationHeader() throws {
        let anonymous = try makeBuilder(token: nil)
        XCTAssertNil(anonymous.pull(after: 0, limit: 1, wait: 0).value(forHTTPHeaderField: "Authorization"))
    }

    func testPairingRequestsCarryNoToken() throws {
        let builder = try makeBuilder()
        let put = try builder.putPairing(id: "0123456789abcdef0123456789abcdef", blob: Data([9]))
        XCTAssertEqual(put.httpMethod, "PUT")
        XCTAssertEqual(put.url?.absoluteString, "http://relay.tailnet:8080/v1/pairing/0123456789abcdef0123456789abcdef")
        XCTAssertNil(put.value(forHTTPHeaderField: "Authorization"))
        let blob = try JSONDecoder().decode(PairingBlob.self, from: try XCTUnwrap(put.httpBody))
        XCTAssertEqual(blob.blob, Data([9]))

        let take = builder.takePairing(id: "0123456789abcdef0123456789abcdef")
        XCTAssertEqual(take.httpMethod, "GET")
        XCTAssertNil(take.value(forHTTPHeaderField: "Authorization"))
    }

    func testStatusMapping() {
        func error(_ status: Int, _ body: String = "") -> TransportError? {
            do {
                try RelayRequestBuilder.check(status: status, body: Data(body.utf8))
                return nil
            } catch {
                return error as? TransportError
            }
        }
        XCTAssertNil(error(200))
        XCTAssertNil(error(204))
        XCTAssertEqual(error(401), .unauthorized)
        XCTAssertEqual(error(403), .unauthorized)
        XCTAssertEqual(error(404), .notFound)
        XCTAssertEqual(error(413), .payloadTooLarge)
        XCTAssertEqual(error(400, "bad after"), .badRequest("bad after"))
        XCTAssertEqual(error(500), .server(500))
        XCTAssertEqual(error(302), .server(302))
    }
}
