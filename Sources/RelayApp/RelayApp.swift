import SwiftUI
import AppKit
import CoreImage.CIFilterBuiltins

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main struct RelayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = RelayModel()
    var body: some Scene {
        Window("Relay", id: "main") {
            MainView(model: model)
                .frame(width: 360)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in model.shutdown() }
        }
        .windowResizability(.contentSize)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Pair Phone") { model.makePairing() }.keyboardShortcut("n").disabled(model.phoneEmail == nil || model.busy)
                Button("Open ChatGPT") { model.openDesktop() }.keyboardShortcut("o").disabled(model.openingDesktop)
                Button(model.isRunning ? "Disconnect" : "Connect") { model.toggleConnection() }.keyboardShortcut("r").disabled(model.phoneEmail == nil)
                Toggle("Keep Mac Awake", isOn: $model.keepAwake).keyboardShortcut("k")
                Button("Import Account…") { model.importProfile() }.keyboardShortcut("i", modifiers: [.command, .shift])
            }
        }

    }
}

struct MainView: View {
    @ObservedObject var model: RelayModel
    private var connectionColor: Color {
        if model.connected && model.runtimeReady { return .green }
        return model.isRunning ? .orange : .secondary
    }
    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(spacing: 12) {
                Button { model.phoneEmail == nil ? model.login() : model.makePairing() } label: {
                    device("iphone", ready: model.phoneEmail != nil)
                }.buttonStyle(.plain).disabled(model.busy).help("Pair phone · ⌘N")
                Menu {
                    if let email = model.phoneEmail {
                        Text(email)
                        Button("Pair device") { model.makePairing() }
                        Button("Sign out", role: .destructive) { model.logout() }
                    } else {
                        Button("Sign in") { model.login() }
                    }
                    Button("Import account…") { model.importProfile() }
                } label: {
                    Text(model.phoneEmail ?? "Add account").lineLimit(1).truncationMode(.middle)
                }.menuStyle(.borderlessButton)
            }.frame(width: 110)
            Button { model.toggleConnection() } label: {
                ZStack {
                    Image(systemName: "link")
                    if !model.connected || !model.runtimeReady {
                        Rectangle().fill(Color(nsColor: .windowBackgroundColor))
                            .frame(width: 4, height: 19).rotationEffect(.degrees(-45))
                    }
                }
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(connectionColor)
                .frame(width: 30, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain).padding(.top, 18).disabled(model.phoneEmail == nil)
            .help("\(model.status) · \(model.isRunning ? "Disconnect" : "Connect") · ⌘R")
            .accessibilityLabel("\(model.status), \(model.isRunning ? "Disconnect" : "Connect")")
            Button { model.openDesktop() } label: {
                VStack(spacing: 12) {
                    device("laptopcomputer", ready: model.runtimeReady)
                    Text(Host.current().localizedName ?? "This Mac")
                        .lineLimit(1).truncationMode(.middle).frame(height: 18)
                }.frame(width: 110)
            }.buttonStyle(.plain).help("Open ChatGPT · ⌘O").disabled(model.openingDesktop)
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .padding(.bottom, 24)
        .navigationTitle("Relay")
        .toolbar {
            if #available(macOS 26, *) {
                ToolbarItem(placement: .principal) { Text("Relay").font(.headline) }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .principal) { Text("Relay").font(.headline) }
            }
        }
        .toolbarBackground(.hidden, for: .windowToolbar)
        .alert("Relay", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
    func device(_ symbol: String, ready: Bool) -> some View {
        Image(systemName: symbol).font(.system(size: 35, weight: .light))
            .foregroundStyle(ready ? .primary : .secondary)
            .frame(width: 100, height: 80)
            .modifier(DeviceGlass())
    }
}

private struct DeviceGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 20))
        } else {
            content.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        }
    }
}

@MainActor final class PairingWindow: NSWindowController, NSWindowDelegate {
    private weak var model: RelayModel?
    init(model: RelayModel) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 216, height: 200),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Pair Phone"; window.isRestorable = false; window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        let content = NSHostingView(rootView: PairingView(model: model))
        content.sizingOptions = []
        content.safeAreaRegions = []
        window.contentView = content
        let size = NSSize(width: 216, height: 200)
        window.setContentSize(size)
        window.contentMinSize = size
        window.contentMaxSize = size
        super.init(window: window)
        window.delegate = self
        if let parent = NSApp.mainWindow {
            let screen = parent.screen?.visibleFrame ?? parent.frame
            let x = min(parent.frame.maxX + 12, screen.maxX - window.frame.width)
            window.setFrameOrigin(NSPoint(x: max(screen.minX, x), y: parent.frame.midY - window.frame.height / 2))
        } else {
            window.center()
        }
    }
    required init?(coder: NSCoder) { nil }
    func windowWillClose(_ notification: Notification) { model?.cancelPairing() }
}

struct PairingView: View {
    @ObservedObject var model: RelayModel
    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 16).fill(model.pairing == nil ? Color(nsColor: .controlBackgroundColor) : .white)
                if let pairing = model.pairing, let image = qr(pairing.url.absoluteString) {
                    Image(nsImage: image).interpolation(.none).resizable().frame(width: 176, height: 176)
                        .accessibilityLabel("Scan to pair ChatGPT Remote")
                } else if model.busy {
                    ProgressView().controlSize(.small)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "qrcode").font(.system(size: 28, weight: .light)).foregroundStyle(.secondary)
                        Text(model.pairingError ?? "Code expired").font(.caption).multilineTextAlignment(.center)
                        Button("Try again") { model.makePairing() }
                    }.padding(16)
                }
            }.frame(width: 196, height: 196)
        }
        .padding(.horizontal, 10)
        .padding(.top, -6)
        .padding(.bottom, 10)
        .frame(width: 216, height: 200)
        .onExitCommand { model.cancelPairing() }
    }
    func qr(_ string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator(); filter.message = Data(string.utf8)
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: image, size: output.extent.size)
    }
}
