// Steam 手柄修正安裝程式：圖形介面安裝／修復／解除安裝 steamac-controller。
// 實際動作交給 app 內附的 patch.sh，介面只負責偵測狀態與呼叫它。
import AppKit
import SwiftUI

let steamBundleID = "com.valvesoftware.steam"
let appManagementSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles")!

// MARK: - 狀態偵測

struct SteamInstall: Identifiable, Hashable {
    let url: URL
    var id: String { url.path }

    var isPatched: Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/MacOS/steam_osx.valve").path)
    }
}

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let dataDir = home.appendingPathComponent(".local/share/steamac-controller")
    static let client = home.appendingPathComponent(
        "Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/steam_osx")
    static let log = home.appendingPathComponent("Library/Logs/steaminput-fix.log")

    static var fixInstalled: Bool {
        FileManager.default.fileExists(atPath: dataDir.appendingPathComponent("libsteaminput-fix.dylib").path)
    }
    static var clientDownloaded: Bool { FileManager.default.isExecutableFile(atPath: client.path) }
}

func findSteamInstalls() -> [SteamInstall] {
    let candidates = [
        URL(fileURLWithPath: "/Applications/Steam.app"),
        Paths.home.appendingPathComponent("Applications/Steam.app"),
    ]
    let byLaunchServices = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: steamBundleID)
        // Steam.AppBundle 裡的用戶端也是同一個 bundle ID，排除它
        .filter { !$0.path.contains("Steam.AppBundle") }
    var seen = Set<String>()
    return (candidates + byLaunchServices)
        .map { $0.standardizedFileURL }
        .filter { FileManager.default.fileExists(atPath: $0.path) && seen.insert($0.path).inserted }
        .map(SteamInstall.init)
}

var steamIsRunning: Bool {
    NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == steamBundleID }
}

// MARK: - 動作

enum Action: String {
    case install, uninstall

    var title: String { self == .install ? "安裝" : "解除安裝" }
}

@MainActor
final class InstallerModel: ObservableObject {
    @Published var installs: [SteamInstall] = []
    @Published var selected: SteamInstall?
    @Published var log = ""
    @Published var busy = false
    @Published var steamRunning = false
    @Published var fixInstalled = false
    @Published var clientDownloaded = false
    @Published var needsPermission = false

    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        let found = findSteamInstalls()
        // 保留使用者手動加入的位置
        let extra = installs.filter { i in !found.contains { $0.id == i.id } && FileManager.default.fileExists(atPath: i.url.path) }
        installs = found + extra
        if let s = selected, let updated = installs.first(where: { $0.id == s.id }) {
            selected = updated
        } else {
            selected = installs.first
        }
        steamRunning = steamIsRunning
        fixInstalled = Paths.fixInstalled
        clientDownloaded = Paths.clientDownloaded
    }

    func addCustomLocation() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = "選擇 Steam.app"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard Bundle(url: url)?.bundleIdentifier == steamBundleID else {
            append("⚠️ \(url.lastPathComponent) 不是 Steam。")
            return
        }
        let install = SteamInstall(url: url)
        if !installs.contains(install) { installs.append(install) }
        selected = install
    }

    func run(_ action: Action) {
        guard let target = selected, let script = Bundle.main.url(forResource: "patch", withExtension: "sh") else {
            append("⚠️ 找不到安裝腳本，請重新下載安裝程式。")
            return
        }
        busy = true
        needsPermission = false
        append("▶︎ \(action.title)：\(target.url.path)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, action.rawValue]
        var env = ProcessInfo.processInfo.environment
        env["STEAM_APP"] = target.url.path
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        process.terminationHandler = { p in
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let status = p.terminationStatus
            Task { @MainActor in
                self.append(output.trimmingCharacters(in: .whitespacesAndNewlines))
                if status == 0 {
                    self.append("✅ \(action.title)完成")
                } else {
                    self.append("❌ \(action.title)失敗（代碼 \(status)）")
                    self.needsPermission = status == 3
                }
                self.busy = false
                self.refresh()
            }
        }
        do {
            try process.run()
        } catch {
            append("❌ 無法執行安裝腳本：\(error.localizedDescription)")
            busy = false
        }
    }

    func restartSteam() {
        guard let target = selected else { return }
        busy = true
        append("▶︎ 重新啟動 Steam")
        for app in NSWorkspace.shared.runningApplications where app.bundleIdentifier == steamBundleID {
            app.terminate()
        }
        Task {
            for _ in 0..<60 where steamIsRunning {
                try? await Task.sleep(for: .milliseconds(500))
            }
            if steamIsRunning {
                append("❌ Steam 沒有結束，請手動結束後再開。")
            } else {
                _ = try? await NSWorkspace.shared.openApplication(at: target.url, configuration: .init())
                append("✅ 已重新開啟 Steam")
            }
            busy = false
            refresh()
        }
    }

    func append(_ text: String) {
        guard !text.isEmpty else { return }
        log += (log.isEmpty ? "" : "\n") + text
    }
}

// MARK: - 介面

extension Color {
    static let background = Color(red: 0.11, green: 0.15, blue: 0.18)
    static let panel = Color(red: 0.15, green: 0.20, blue: 0.24)
    static let banner = Color(red: 0.91, green: 0.82, blue: 0.24)
    static let installGreen = Color(red: 0.0, green: 0.53, blue: 0.25)
    static let repairBlue = Color(red: 0.35, green: 0.40, blue: 0.95)
    static let uninstallRed = Color(red: 0.89, green: 0.0, blue: 0.20)
}

struct ActionButton: View {
    let title: String
    let color: Color
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, design: .monospaced))
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(.white)
                .background(color.opacity(enabled ? 1 : 0.35), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

struct StatusRow: View {
    let ok: Bool
    let text: String

    var body: some View {
        Label(text, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
            .foregroundStyle(ok ? Color.green : Color.orange)
            .font(.system(size: 13, design: .monospaced))
    }
}

struct ContentView: View {
    @StateObject private var model = InstallerModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Steam 手柄修正安裝程式")
                .font(.system(size: 30, weight: .medium, design: .monospaced))
                .frame(maxWidth: .infinity)
                .padding(.top, 8)

            Text("""
            讓 Steam Controller 在 Mac 的 Steam 遊戲裡可以操控：修正 Steam Input 的虛擬手柄，\
            讓遊戲能辨識它。安裝會修補 Steam.app（自動備份原版，解除安裝即可還原），之後照常從 Steam 開遊戲。
            """)
            .font(.system(size: 13, design: .monospaced))
            .foregroundStyle(.black)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.banner, in: RoundedRectangle(cornerRadius: 6))

            Text("請選擇要修補的 Steam")
                .font(.system(size: 20, design: .monospaced))

            VStack(alignment: .leading, spacing: 8) {
                if model.installs.isEmpty {
                    Text("找不到 Steam.app，請先安裝 Steam。")
                        .foregroundStyle(.orange)
                }
                ForEach(model.installs) { install in
                    Button {
                        model.selected = install
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: model.selected == install ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(Color.accentColor)
                            Text(install.isPatched ? "Steam（已安裝修正）" : "Steam")
                            Text(install.url.path).foregroundStyle(.secondary)
                        }
                        .font(.system(size: 14, design: .monospaced))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Button("其他位置…") { model.addCustomLocation() }
                    .buttonStyle(.link)
                    .font(.system(size: 12, design: .monospaced))
            }

            HStack(spacing: 14) {
                let patched = model.selected?.isPatched ?? false
                let hasTarget = model.selected != nil && !model.busy
                ActionButton(title: "安裝", color: .installGreen, enabled: hasTarget && !patched) {
                    model.run(.install)
                }
                ActionButton(title: "重新安裝 / 修復", color: .repairBlue, enabled: hasTarget && patched) {
                    model.run(.install)
                }
                ActionButton(title: "解除安裝", color: .uninstallRed,
                             enabled: hasTarget && (patched || model.fixInstalled)) {
                    model.run(.uninstall)
                }
            }

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    StatusRow(ok: model.clientDownloaded,
                              text: model.clientDownloaded ? "Steam 用戶端已下載" : "Steam 用戶端尚未下載：請先開一次 Steam 並登入")
                    StatusRow(ok: model.fixInstalled, text: model.fixInstalled ? "修正檔已安裝" : "修正檔未安裝")
                    if model.steamRunning {
                        StatusRow(ok: false, text: "Steam 執行中：安裝／解除後要重開 Steam 才生效")
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    if model.steamRunning {
                        Button("重新啟動 Steam") { model.restartSteam() }
                            .disabled(model.busy)
                    }
                    if model.needsPermission {
                        Button("開啟「App 管理」設定") { NSWorkspace.shared.open(appManagementSettingsURL) }
                    }
                    Button("顯示紀錄檔") {
                        NSWorkspace.shared.activateFileViewerSelecting([Paths.log])
                    }
                    .buttonStyle(.link)
                }
            }

            if model.needsPermission {
                Text("需要「系統設定 → 隱私權與安全性 → App 管理」允許本安裝程式，開啟後請重開安裝程式再試一次。")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.orange)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    Text(model.log.isEmpty ? "執行紀錄會顯示在這裡。" : model.log)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(model.log.isEmpty ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(10)
                    Color.clear.frame(height: 1).id("bottom")
                }
                .background(Color.panel, in: RoundedRectangle(cornerRadius: 6))
                .onChange(of: model.log) { proxy.scrollTo("bottom") }
            }
        }
        .padding(28)
        .frame(minWidth: 760, minHeight: 600)
        .background(Color.background)
        .preferredColorScheme(.dark)
    }
}

@main
struct InstallerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Steam 手柄修正安裝程式") {
            ContentView()
        }
        .windowResizability(.contentMinSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
