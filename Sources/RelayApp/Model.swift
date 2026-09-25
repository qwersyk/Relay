import SwiftUI
import AppKit
import RelayCore
import IOKit.pwr_mgt

@MainActor final class RelayModel: ObservableObject {
    @Published var phoneEmail: String?
    @Published var status = "Offline"
    @Published var connected = false { didSet { updatePower() } }
    @Published var isRunning = false { didSet { updatePower() } }
    @Published var busy = false
    @Published var openingDesktop = false
    @Published var keepAwake = false { didSet { updatePower() } }
    @Published var runtimeReady = false { didSet { updatePower() } }
    @Published private(set) var keepingAwake = false
    private var powerAssertion: IOPMAssertionID = 0
    @Published var pairing: Pairing?
    @Published var pairingError: String?
    private var pairingWindow: PairingWindow?
    @Published var error: String?
    let paths = RelayPaths()
    lazy var identity = PhoneIdentity(paths: paths)
    lazy var api = RemoteAPI(identity: identity, installationID: installationID, name: "Relay · \(Host.current().localizedName ?? "Mac")")
    private var gateway: Gateway?
    private var pairingTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var monitor: ProcessChannel?
    var installationID: String {
        if let v = UserDefaults.standard.string(forKey: "installationID") { return v }
        let v = UUID().uuidString.lowercased(); UserDefaults.standard.set(v, forKey: "installationID"); return v
    }
    init() {
        do { try identity.restore(); phoneEmail = identity.profile?.email; try api.restore() }
        catch { self.error = "Sign in or import your phone account." }
        identity.onLogin = { [weak self] in
            guard let self else { return }; self.phoneEmail = self.identity.profile?.email; self.busy = false; self.connect(); self.makePairing()
        }
        if phoneEmail != nil && UserDefaults.standard.bool(forKey: "remoteEnabled") { Task { [weak self] in self?.connect() } }
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkRuntime()
                try? await Task.sleep(nanoseconds: 15_000_000_000)
            }
        }
    }
    func checkRuntime() async {
        if monitor != nil { return }
        guard FileManager.default.fileExists(atPath: paths.socket.path) else { runtimeReady = false; return }
        let c = ProcessChannel()
        do {
            try c.start(executable: paths.cli, arguments: ["app-server", "proxy", "--sock", paths.socket.path])
            _ = try await c.initialize(name: "relay_status")
            monitor = c; runtimeReady = true
            c.onClose = { [weak self] in self?.runtimeReady = false; self?.monitor = nil }
        } catch { c.close(); runtimeReady = false }
    }
    func importProfile() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        panel.message = "Choose the account used on your phone."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            guard data.count < 2_000_000 else { throw RelayError.message("Profile file is too large.") }
            let candidate = try AccountProfile(data: data)
            let changed = identity.profile?.accountID != candidate.accountID
            stop()
            try identity.importProfile(data)
            if changed { api.resetLocalEnrollment() }
            phoneEmail = identity.profile?.email; error = nil; connect(); makePairing()
        } catch { self.error = error.localizedDescription }
    }
    func login() {
        busy = true; error = nil
        Task {
            do { let url = try await identity.beginLogin(); NSWorkspace.shared.open(url); busy = false }
            catch { self.error = "Sign-in failed. Try importing your account."; busy = false }
        }
    }
    func connect() {
        guard phoneEmail != nil, !isRunning else { return }
        isRunning = true; error = nil; UserDefaults.standard.set(true, forKey: "remoteEnabled")
        let bridge = Gateway(api: api, paths: paths); gateway = bridge
        bridge.onState = { [weak self] state in
            guard let self else { return }
            switch state {
            case .stopped: self.status = "Offline"; self.connected = false
            case .connecting: self.status = "Connecting"; self.connected = false
            case .online: self.status = "Connected"; self.connected = true
            case .retrying(let seconds): self.status = "Retrying in \(seconds)s"; self.connected = false
            case .failed(let message): self.error = message; self.status = "Needs attention"; self.connected = false; self.isRunning = false
            }
        }
        bridge.start()
    }
    func makePairing() {
        guard !busy else { return }; busy = true; error = nil; pairingError = nil; pairing = nil
        if pairingWindow == nil { pairingWindow = PairingWindow(model: self) }
        pairingWindow?.showWindow(nil)
        if !isRunning { connect() }
        pairingTask?.cancel()
        pairingTask = Task {
            do {
                let value = try await api.pair(); try Task.checkCancellation(); pairing = value; busy = false
                while !Task.isCancelled, value.expires > Date() {
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                    if try await api.claimed(value) { cancelPairing(); return }
                }
                pairing = nil
            } catch is CancellationError { busy = false }
            catch { self.pairingError = (error as? RemoteAPIError)?.localizedDescription ?? "Could not connect."; busy = false }
        }
    }
    func cancelPairing() {
        pairingTask?.cancel(); pairingTask = nil; pairing = nil; pairingError = nil; busy = false
        let window = pairingWindow; pairingWindow = nil; window?.close()
    }
    func stop() {
        UserDefaults.standard.set(false, forKey: "remoteEnabled")
        cancelPairing()
        gateway?.stop(); gateway = nil; isRunning = false; connected = false
    }
    func logout() { stop(); api.resetLocalEnrollment(); identity.logout(); phoneEmail = nil }
    func toggleConnection() { isRunning ? stop() : connect() }
    private func usesRelay(_ app: NSRunningApplication) -> Bool {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "ppid=,comm="]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        let rows = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return rows.split(separator: "\n").contains {
            let fields = $0.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            return fields.count == 2 && Int32(fields[0]) == app.processIdentifier && fields[1].hasSuffix("/Contents/Helpers/relay-cli")
        }
    }
    func openDesktop() {
        guard !openingDesktop else { return }
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").filter { !$0.isTerminated }
        if runtimeReady, let app = apps.first, usesRelay(app) { app.activate(options: [.activateAllWindows]); return }
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/relay-cli")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { error = "Open the built Relay.app."; return }
        openingDesktop = true; error = nil
        Task {
            defer { openingDesktop = false }
            // Ask ChatGPT to quit normally, allowing it to finish its own shutdown.
            for app in apps { app.terminate() }
            for _ in 0..<100 {
                if apps.allSatisfy({ $0.isTerminated }) { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard apps.allSatisfy({ $0.isTerminated }) else {
                error = "ChatGPT could not quit. Finish any open dialog and try again."; return
            }
            let config = NSWorkspace.OpenConfiguration()
            config.environment = ["CODEX_CLI_PATH": helper.path, "CODEX_APP_SERVER_FORCE_CLI": "1"]
            do {
                _ = try await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Applications/ChatGPT.app"), configuration: config)
                await checkRuntime()
            } catch { self.error = "Could not open ChatGPT." }
        }
    }
    private func updatePower() {
        let needed = keepAwake && isRunning && connected && runtimeReady
        if needed && !keepingAwake {
            keepingAwake = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn), "Relay Remote connection" as CFString, &powerAssertion) == kIOReturnSuccess
            if !keepingAwake { error = "Could not keep this Mac awake. Check its sleep settings." }
        } else if !needed && keepingAwake {
            IOPMAssertionRelease(powerAssertion); powerAssertion = 0; keepingAwake = false
        }
    }
    func shutdown() { let resume = isRunning; stop(); UserDefaults.standard.set(resume, forKey: "remoteEnabled"); monitorTask?.cancel(); monitor?.close(); monitor = nil }
}
