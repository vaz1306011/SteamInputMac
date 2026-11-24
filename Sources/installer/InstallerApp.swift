// SteamInputMac Installer：圖形介面安裝／修復／解除安裝 SteamInputMac。
// 實際動作交給 app 內附的 patch.sh，介面只負責偵測狀態與呼叫它。
import AppKit
import SwiftUI

let steamBundleID = "com.valvesoftware.steam"
let appManagementSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles")!
let latestReleaseAPI = URL(string: "https://api.github.com/repos/vaz1306011/SteamInputMac/releases/latest")!
let releasesPageURL = URL(string: "https://github.com/vaz1306011/SteamInputMac/releases")!
/// patch.sh 安裝時需要的檔案（安裝程式 Resources 裡的內容）
let payloadFiles = ["patch.sh", "steam_osx", "launch.sh", "libSteamInputMac.dylib"]

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
    static let dataDir = home.appendingPathComponent(".local/share/steaminputmac")
    static let client = home.appendingPathComponent(
        "Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/steam_osx")
    static let log = home.appendingPathComponent("Library/Logs/SteamInputMac.log")
    static let downloads = home.appendingPathComponent("Library/Caches/SteamInputMac")

    static var fixInstalled: Bool {
        FileManager.default.fileExists(atPath: dataDir.appendingPathComponent("libSteamInputMac.dylib").path)
    }
    static var clientDownloaded: Bool { FileManager.default.isExecutableFile(atPath: client.path) }

    /// 目前安裝的修正檔版本；舊版安裝沒有記錄版本則為 nil
    static var installedVersion: String? {
        guard fixInstalled else { return nil }
        let text = try? String(contentsOf: dataDir.appendingPathComponent("VERSION"), encoding: .utf8)
        return text?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// 安裝程式本身內附的版本
let bundledVersion: String = {
    if let url = Bundle.main.url(forResource: "VERSION", withExtension: nil),
       let text = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
       !text.isEmpty {
        return text
    }
    return Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
}()

// MARK: - 版本

/// 「v1.2.0」→ [1, 2, 0]；不是數字版本（例如 dev）回傳 nil
func versionComponents(_ version: String) -> [Int]? {
    let trimmed = version.hasPrefix("v") ? String(version.dropFirst()) : version
    let parts = trimmed.split(separator: ".").map { Int($0) }
    guard !parts.isEmpty, !parts.contains(nil) else { return nil }
    return parts.map { $0! }
}

/// a 是否比 b 新；任一方不是數字版本時，只要不同就視為較新
func isNewer(_ a: String, than b: String) -> Bool {
    guard var x = versionComponents(a), var y = versionComponents(b) else { return a != b }
    let n = max(x.count, y.count)
    x += Array(repeating: 0, count: n - x.count)
    y += Array(repeating: 0, count: n - y.count)
    return x.lexicographicallyPrecedes(y) == false && x != y
}

struct Release: Decodable {
    struct Asset: Decodable {
        let name: String
        let browser_download_url: URL
    }
    let tag_name: String
    let assets: [Asset]

    var version: String { tag_name.hasPrefix("v") ? String(tag_name.dropFirst()) : tag_name }
    var dmg: Asset? { assets.first { $0.name.hasSuffix(".dmg") } }
}

enum LatestState {
    case checking
    case found(Release)
    case failed(String)
}

struct CommandError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// 執行指令並等待結束，失敗時丟出含輸出的錯誤
@discardableResult
func runCommand(_ path: String, _ args: [String]) async throws -> String {
    try await withCheckedThrowingContinuation { cont in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.terminationHandler = { p in
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            if p.terminationStatus == 0 {
                cont.resume(returning: output)
            } else {
                cont.resume(throwing: CommandError(message: "\((path as NSString).lastPathComponent) 失敗：\(output)"))
            }
        }
        do { try process.run() } catch { cont.resume(throwing: error) }
    }
}

/// 下載指定 release 的 DMG，取出安裝程式內附的檔案放到快取資料夾，回傳該資料夾。
/// 已經下載過的版本直接沿用。
func preparePayload(for release: Release, log: @MainActor (String) -> Void) async throws -> URL {
    let fm = FileManager.default
    let dir = Paths.downloads.appendingPathComponent(release.version)
    if payloadFiles.allSatisfy({ fm.fileExists(atPath: dir.appendingPathComponent($0).path) }) {
        await log("使用已下載的 \(release.version)")
        return dir
    }
    guard let asset = release.dmg else { throw CommandError(message: "這個版本沒有 DMG 可下載") }

    await log("下載 \(asset.name)…")
    let (tmp, response) = try await URLSession.shared.download(from: asset.browser_download_url)
    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
        throw CommandError(message: "下載失敗（HTTP \(http.statusCode)）")
    }
    try fm.createDirectory(at: Paths.downloads, withIntermediateDirectories: true)
    let dmg = Paths.downloads.appendingPathComponent(asset.name)
    try? fm.removeItem(at: dmg)
    try fm.moveItem(at: tmp, to: dmg)
    defer { try? fm.removeItem(at: dmg) }

    let mount = fm.temporaryDirectory.appendingPathComponent("SteamInputMac-\(UUID().uuidString)")
    try fm.createDirectory(at: mount, withIntermediateDirectories: true)
    await log("掛載 DMG…")
    try await runCommand("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen",
                                              "-mountpoint", mount.path])
    do {
        try copyPayload(from: mount, to: dir, version: release.version)
    } catch {
        _ = try? await runCommand("/usr/bin/hdiutil", ["detach", mount.path])
        throw error
    }
    _ = try? await runCommand("/usr/bin/hdiutil", ["detach", mount.path])
    try? fm.removeItem(at: mount)
    return dir
}

/// 從掛載的 DMG 取出安裝程式內附的檔案到 dir
func copyPayload(from mount: URL, to dir: URL, version: String) throws {
    let fm = FileManager.default
    let apps = try fm.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil).filter { $0.pathExtension == "app" }
    guard let resources = apps.map({ $0.appendingPathComponent("Contents/Resources") })
        .first(where: { fm.fileExists(atPath: $0.appendingPathComponent("patch.sh").path) }) else {
        throw CommandError(message: "DMG 裡找不到安裝檔案")
    }

    // 先放到暫存資料夾，全部複製成功再換上，避免留下不完整的快取
    let staging = Paths.downloads.appendingPathComponent(".\(version).partial")
    try? fm.removeItem(at: staging)
    try fm.createDirectory(at: staging, withIntermediateDirectories: true)
    for name in payloadFiles + ["VERSION"] {
        let src = resources.appendingPathComponent(name)
        if fm.fileExists(atPath: src.path) {
            try fm.copyItem(at: src, to: staging.appendingPathComponent(name))
        } else if payloadFiles.contains(name) {
            throw CommandError(message: "DMG 裡缺少 \(name)")
        }
    }
    try? fm.removeItem(at: dir)
    try fm.moveItem(at: staging, to: dir)
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
    @Published var installedVersion: String?
    @Published var latest: LatestState = .checking

    private var timer: Timer?

    init() {
        refresh()
        checkLatest()
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
        installedVersion = Paths.installedVersion
    }

    var latestRelease: Release? {
        if case .found(let r) = latest { return r }
        return nil
    }

    /// 有比目前安裝的（未安裝時則比安裝程式內附的）更新的版本可裝
    var updateAvailable: Bool {
        guard let r = latestRelease else { return false }
        guard fixInstalled else { return isNewer(r.version, than: bundledVersion) }
        guard let installed = installedVersion else { return true }
        return isNewer(r.version, than: installed)
    }

    func checkLatest() {
        latest = .checking
        Task {
            do {
                var request = URLRequest(url: latestReleaseAPI)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    throw CommandError(message: "HTTP \(http.statusCode)")
                }
                latest = .found(try JSONDecoder().decode(Release.self, from: data))
            } catch {
                latest = .failed(error.localizedDescription)
            }
        }
    }

    /// 下載最新版並安裝，不需要重新下載安裝程式
    func installLatest() {
        guard let release = latestRelease else { return }
        busy = true
        needsPermission = false
        append("▶︎ 取得最新版 \(release.version)")
        Task {
            do {
                let dir = try await preparePayload(for: release) { self.append($0) }
                busy = false
                run(.install, from: dir, version: release.version)
            } catch {
                append("❌ 取得最新版失敗：\(error.localizedDescription)")
                busy = false
            }
        }
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

    /// dir 為 nil 時用安裝程式內附的檔案；version 會記錄成安裝的版本
    func run(_ action: Action, from dir: URL? = nil, version: String? = nil) {
        let script = dir?.appendingPathComponent("patch.sh") ?? Bundle.main.url(forResource: "patch", withExtension: "sh")
        guard let target = selected, let script, FileManager.default.fileExists(atPath: script.path) else {
            append("⚠️ 找不到安裝腳本，請重新下載安裝程式。")
            return
        }
        busy = true
        needsPermission = false
        append("▶︎ \(action.title)\(version.map { " \($0)" } ?? "")：\(target.url.path)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, action.rawValue]
        var env = ProcessInfo.processInfo.environment
        env["STEAM_APP"] = target.url.path
        if let version { env["SIM_VERSION"] = version }
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

struct VersionPanel: View {
    @ObservedObject var model: InstallerModel

    var latestText: String {
        switch model.latest {
        case .checking: return "檢查中…"
        case .found(let r): return r.version
        case .failed: return "無法取得"
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                Text("目前安裝：\(model.fixInstalled ? (model.installedVersion ?? "不明（舊版）") : "未安裝")")
                HStack(spacing: 6) {
                    Text("最新版本：\(latestText)")
                    if case .failed(let message) = model.latest {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).help(message)
                    }
                    Button {
                        model.checkLatest()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("重新檢查")
                    Button("Releases") { NSWorkspace.shared.open(releasesPageURL) }
                        .buttonStyle(.link)
                }
                Text("安裝程式內附：\(bundledVersion)").foregroundStyle(.secondary)
            }
            .font(.system(size: 13, design: .monospaced))

            Spacer()

            if model.updateAvailable, let r = model.latestRelease {
                ActionButton(title: model.fixInstalled ? "更新到 \(r.version)" : "安裝最新版 \(r.version)", color: .installGreen,
                             enabled: model.selected != nil && !model.busy) {
                    model.installLatest()
                }
                .frame(width: 220)
            } else if model.fixInstalled, model.latestRelease != nil {
                Label("已是最新版", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 13, design: .monospaced))
            }
        }
        .padding(12)
        .background(Color.panel, in: RoundedRectangle(cornerRadius: 6))
    }
}

struct ContentView: View {
    @StateObject private var model = InstallerModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(spacing: 4) {
                Text("SteamInputMac")
                    .font(.system(size: 30, weight: .medium, design: .monospaced))
                Text("Steam 手柄修正安裝程式")
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
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

            VersionPanel(model: model)

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
        WindowGroup("SteamInputMac Installer") {
            ContentView()
        }
        .windowResizability(.contentMinSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
