import XCTest
@testable import RelayCore

final class RuntimeTests: XCTestCase {
    @MainActor func testTwoClientsShareRealCodexRuntime() async throws {
        let cli = "/Applications/ChatGPT.app/Contents/Resources/codex"
        guard FileManager.default.isExecutableFile(atPath: cli) else { throw XCTSkip("Installed ChatGPT runtime required") }
        let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("relay-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: home) }
        let socket = home.appendingPathComponent("r.sock")
        let runtime = Process(); runtime.executableURL = URL(fileURLWithPath: cli)
        runtime.arguments = ["app-server", "--listen", "unix://" + socket.path]
        var env = ProcessInfo.processInfo.environment; env["CODEX_HOME"] = home.path
        runtime.environment = env; runtime.standardOutput = FileHandle.nullDevice; runtime.standardError = FileHandle.standardError; runtime.standardInput = FileHandle.nullDevice
        try runtime.run()
        defer { if runtime.isRunning { runtime.terminate(); runtime.waitUntilExit() } }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: socket.path) { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        print("Runtime running:", runtime.isRunning, "Socket:", socket.path, "exists:", FileManager.default.fileExists(atPath: socket.path))
        let a = ProcessChannel(), b = ProcessChannel()
        defer { a.close(); b.close() }
        try a.start(executable: cli, arguments: ["app-server", "proxy", "--sock", socket.path])
        try b.start(executable: cli, arguments: ["app-server", "proxy", "--sock", socket.path])
        let ai = try await a.initialize(name: "relay_test_desktop")
        let bi = try await b.initialize(name: "relay_test_phone")
        XCTAssertEqual(ai["codexHome"], bi["codexHome"])
        let initial = try await a.call("thread/list", .object(["limit": .number(10)]))
        XCTAssertNotNil(initial["data"].array)
        let thread = try await a.call("thread/start", .object(["cwd": .string(home.path), "approvalPolicy": .string("on-request"), "sandbox": .string("read-only")]))
        let id = try XCTUnwrap(thread["thread"]["id"].string)
        let loaded = try await b.call("thread/loaded/list")
        XCTAssertTrue(loaded["data"].array?.contains(.string(id)) == true)
        let read = try await b.call("thread/read", .object(["threadId": .string(id)]))
        XCTAssertEqual(read["thread"]["id"].string, id)
        // Closing the phone connection must not kill the desktop's server.
        b.close()
        let after = try await a.call("thread/loaded/list")
        XCTAssertTrue(after["data"].array?.contains(.string(id)) == true)
    }
    @MainActor func testGatewayRecoversAfterRuntimeRestart() async throws {
        let root = URL(fileURLWithPath: "/tmp/rly-" + UUID().uuidString.prefix(8))
        let paths = RelayPaths(root: root)
        try paths.prepare()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("codex"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var runtime: Process?
        defer { if let runtime, runtime.isRunning { runtime.terminate(); runtime.waitUntilExit() } }
        func launch() async throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: paths.cli)
            process.arguments = ["app-server", "--listen", "unix://" + paths.socket.path]
            var env = ProcessInfo.processInfo.environment; env["CODEX_HOME"] = root.appendingPathComponent("codex").path
            process.environment = env
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.standardError
            try process.run(); runtime = process
            for _ in 0..<100 {
                if FileManager.default.fileExists(atPath: paths.socket.path) { return }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            throw RelayError.message("Test runtime did not start")
        }
        let identity = PhoneIdentity(paths: paths)
        let api = RemoteAPI(identity: identity, installationID: "test-only", name: "Test")
        let gateway = Gateway(api: api, paths: paths)
        defer { gateway.stop() }
        var sequence = 0
        func request(_ id: Int, _ method: String, _ params: JSON = .object([:])) async throws -> JSON {
            sequence += 1
            try await gateway.receive(.object([
                "type": .string("client_message"), "client_id": .string("test-phone"),
                "stream_id": .string("restart-test"), "seq_id": .number(Double(sequence)),
                "message": .object(["id": .number(Double(id)), "method": .string(method), "params": params])
            ]))
            for _ in 0..<100 {
                for frame in gateway.outbox.frames {
                    let message = try JSON(data: frame.data)["message"]
                    if message["id"] == .number(Double(id)) { return message }
                }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            throw RelayError.message("No gateway response to \(method)")
        }
        let initialize: JSON = .object([
            "clientInfo": .object(["name": .string("relay_test_phone"), "version": .string("1")]),
            "capabilities": .object(["experimentalApi": .bool(true)])
        ])
        try await launch()
        let first = try await request(1, "initialize", initialize)
        XCTAssertEqual(first["error"], .null)
        let created = try await request(2, "thread/start", .object([
            "cwd": .string(root.path), "approvalPolicy": .string("on-request"), "sandbox": .string("read-only")
        ]))
        XCTAssertNotNil(created["result"]["thread"]["id"].string)
        runtime?.terminate(); runtime?.waitUntilExit()
        try await Task.sleep(nanoseconds: 200_000_000)
        let disconnected = try await request(3, "thread/list")
        XCTAssertEqual(disconnected["error"]["code"], .number(-32000))
        try await launch()
        let reconnected = try await request(4, "initialize", initialize)
        XCTAssertEqual(reconnected["error"], .null)
        let listed = try await request(5, "thread/list", .object(["limit": .number(10)]))
        XCTAssertNotNil(listed["result"]["data"].array)
    }
    @MainActor func testMissingSocketFailsWithoutHanging() async throws {
        let channel = ProcessChannel()
        try channel.start(executable: "/unused", arguments: ["proxy", "--sock", "/tmp/relay-does-not-exist.sock"])
        do { _ = try await channel.initialize(name: "relay_test"); XCTFail("Expected disconnect") } catch { }
        channel.close()
    }
}
