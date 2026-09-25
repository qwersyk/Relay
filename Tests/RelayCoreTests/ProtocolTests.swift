import XCTest
@testable import RelayCore

final class ProtocolTests: XCTestCase {
    let key = StreamKey(client: "phone", stream: "stream-a")
    func testChunkRoundTripWithUnicodeAndReplay() throws {
        let message: JSON = .object(["id": .number(42), "result": .string(String(repeating: "Привет 👋\n", count: 40000))])
        let frames = try WireProtocol.frames(message: message, key: key, sequence: 7)
        XCTAssertGreaterThan(frames.count, 1)
        var assembler = ChunkAssembler(), reconstructed: JSON?
        for frame in frames {
            XCTAssertLessThanOrEqual(frame.data.count, 150 * 1024)
            var envelope = try JSON(data: frame.data); envelope["type"] = .string("client_message_chunk")
            reconstructed = try assembler.accept(envelope, key: key)
            if reconstructed == nil { XCTAssertNil(try assembler.accept(envelope, key: key)) }
        }
        XCTAssertEqual(reconstructed, message)
    }
    func testMalformedChunkFailsClosed() throws {
        var assembler = ChunkAssembler()
        let e: JSON = .object(["seq_id": .number(0), "segment_id": .number(0), "segment_count": .number(1025), "message_size_bytes": .number(1), "message_chunk_base64": .string("YQ==")])
        XCTAssertThrowsError(try assembler.accept(e, key: key))
    }
    func testAcksAreScopedToClientAndStream() throws {
        var box = Outbox()
        let other = StreamKey(client: "phone", stream: "stream-b")
        try box.append(WireProtocol.frames(message: .string("one"), key: key, sequence: 1))
        try box.append(WireProtocol.frames(message: .string("two"), key: other, sequence: 1))
        box.acknowledge(key: key, sequence: 1, segment: nil)
        XCTAssertEqual(box.frames.count, 1); XCTAssertEqual(box.frames[0].key, other)
        box.acknowledge(key: other, sequence: 1, segment: nil)
        XCTAssertEqual(box.bytes, 0)
    }
    func testPartialChunkAckKeepsRemainingFrames() throws {
        var box = Outbox()
        let frames = try WireProtocol.frames(message: .string(String(repeating: "x", count: 450000)), key: key, sequence: 5)
        try box.append(frames); box.acknowledge(key: key, sequence: 5, segment: 1)
        XCTAssertEqual(box.frames.count, frames.count - 2)
        XCTAssertTrue(box.frames.allSatisfy { ($0.segment ?? 0) > 1 })
    }
    func testQueueOverflowIsAtomic() throws {
        var box = Outbox(limit: 10)
        XCTAssertThrowsError(try box.append(WireProtocol.frames(message: .string("test"), key: key, sequence: 1)))
        XCTAssertEqual(box.bytes, 0); XCTAssertTrue(box.frames.isEmpty)
    }
    func testSecretsAndLocalVerificationAreNeverProxied() {
        for method in ["account/login/start", "account/logout", "getAuthStatus", "userVerification/verify", "userVerification/enroll", "remoteControl/pairing/start"] { XCTAssertFalse(WireProtocol.permits(method)) }
        for method in ["initialize", "thread/list", "thread/start", "turn/start", "turn/interrupt", "account/read"] { XCTAssertTrue(WireProtocol.permits(method)) }
    }
    func testProfileImportAndRejectAmbiguousAccount() throws {
        let auth = "{\"tokens\":{\"account_id\":\"test\",\"access_token\":\"not-a-real-token\"}}"
        let raw = try JSON.object(["profiles": .array([.object(["authJSONString": .string(auth)])])]).data()
        XCTAssertEqual(try AccountProfile(data: raw).accountID, "test")
        XCTAssertThrowsError(try AccountProfile(data: Data("{\"profiles\":[]}".utf8)))
        XCTAssertThrowsError(try AccountProfile(data: Data("{\"OPENAI_API_KEY\":\"example\"}".utf8)))
    }
    @MainActor func testPrivateIdentityPersistsAndStaysSignedOut() throws {
        let root = URL(fileURLWithPath: "/tmp/rly-auth-" + UUID().uuidString.prefix(8))
        let paths = RelayPaths(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let auth = Data("{\"tokens\":{\"account_id\":\"test-only\",\"access_token\":\"not-a-token\"}}".utf8)
        let first = PhoneIdentity(paths: paths)
        try first.importProfile(auth)
        let second = PhoneIdentity(paths: paths)
        try second.restore()
        XCTAssertEqual(second.profile?.accountID, "test-only")
        let attributes = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("phone-account.json").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let directory = try FileManager.default.attributesOfItem(atPath: root.path)
        XCTAssertEqual((directory[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        second.logout()
        // Even a stale working copy must not resurrect a signed-out identity.
        try RelayPaths.privateWrite(auth, to: paths.identity.appendingPathComponent("auth.json"))
        let third = PhoneIdentity(paths: paths)
        try third.restore()
        XCTAssertNil(third.profile)
        XCTAssertThrowsError(try Vault.put(auth, key: "../escape", paths: paths))
    }
    func testJSONRetainsNullAndBoolean() throws {
        let sample: JSON = .object(["id": .number(5), "params": .object(["enabled": .bool(true), "optional": .null])])
        XCTAssertEqual(try JSON(data: sample.data()), sample)
    }
    @MainActor func testDisconnectedPeerGetsResponseAndPairingIsNotRequired() async throws {
        let paths = RelayPaths(root: URL(fileURLWithPath: "/tmp/relay-no-runtime-test"))
        let identity = PhoneIdentity(paths: paths)
        let api = RemoteAPI(identity: identity, installationID: "test-only", name: "Test")
        let gateway = Gateway(api: api, paths: paths)
        let request: JSON = .object([
            "type": .string("client_message"), "client_id": .string("test-phone"),
            "stream_id": .string("disconnected-stream"), "seq_id": .number(1),
            "message": .object(["id": .number(99), "method": .string("thread/list"), "params": .object([:])])
        ])
        try await gateway.receive(request)
        XCTAssertEqual(gateway.outbox.frames.count, 1)
        let response = try JSON(data: gateway.outbox.frames[0].data)
        XCTAssertEqual(response["message"]["id"], .number(99))
        XCTAssertEqual(response["message"]["error"]["code"], .number(-32000))
        // A replay of the same sequence must not create a second response or execute a command.
        try await gateway.receive(request)
        XCTAssertEqual(gateway.outbox.frames.count, 1)
        gateway.stop()
    }

}
