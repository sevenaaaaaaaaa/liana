import AppKit

// MARK: - 主题（皮肤包）

/// 候选窗主题：来自皮肤包的 theme.json；nil 字段回落到系统语义色。
/// theme.json 形如：
/// {"light":{"surface":"#FFFFFFE0","text":"#222222","comment":"#888888",
///           "accent":"#337BFF","radius":18,"font_size":17},
///  "dark":{...}}
struct CandidateTheme {
    struct Side: Equatable {
        var surface: NSColor?
        var text: NSColor?
        var comment: NSColor?
        var accent: NSColor?
        var radius: CGFloat?
        var fontSize: CGFloat?
    }

    var light: Side
    var dark: Side

    /// 跟随系统：全部走语义色（默认外观，即旧版表现）。
    static let system = CandidateTheme(light: .init(), dark: .init())

    static func load(from dir: URL) -> CandidateTheme? {
        guard
            let data = try? Data(contentsOf: dir.appendingPathComponent("theme.json")),
            let decoded = try? JSONDecoder().decode(ThemeFile.self, from: data)
        else { return nil }
        return CandidateTheme(
            light: decoded.light?.side ?? .init(),
            dark: decoded.dark?.side ?? .init()
        )
    }

    /// 按当前系统外观取侧。
    var current: Side {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
    }

    struct ThemeFile: Codable {
        let light: SideFile?
        let dark: SideFile?

        struct SideFile: Codable {
            var surface: String?
            var text: String?
            var comment: String?
            var accent: String?
            var radius: Double?
            var font_size: Double?

            var side: CandidateTheme.Side {
                var result = CandidateTheme.Side()
                if let v = surface { result.surface = parseHexColor(v) }
                if let v = text { result.text = parseHexColor(v) }
                if let v = comment { result.comment = parseHexColor(v) }
                if let v = accent { result.accent = parseHexColor(v) }
                if let v = radius { result.radius = CGFloat(v) }
                if let v = font_size { result.fontSize = CGFloat(v) }
                return result
            }
        }
    }
}

/// #RGB / #RRGGBB / #RRGGBBAA → NSColor（sRGB）。
func parseHexColor(_ hex: String) -> NSColor? {
    var value = hex.trimmingCharacters(in: .whitespaces)
    if value.hasPrefix("#") { value.removeFirst() }
    guard value.allSatisfy(\.isHexDigit) else { return nil }
    // #RGB 简写展开成 6 位
    if value.count == 3 {
        value = value.map { "\($0)\($0)" }.joined()
    }
    let chars = Array(value)
    func channel(_ i: Int) -> CGFloat {
        let digits = String(chars[i]) + String(chars[i + 1])
        return CGFloat(Int(digits, radix: 16) ?? 0) / 255.0
    }
    switch chars.count {
    case 6:
        return NSColor(red: channel(0), green: channel(2), blue: channel(4), alpha: 1)
    case 8:
        return NSColor(red: channel(2), green: channel(4), blue: channel(6), alpha: channel(0))
    default:
        return nil
    }
}

// MARK: - 插件目录（内核扫描）

/// 插件包目录清单（与内核 catalog JSON 对应）。
struct PluginCatalog: Codable {
    struct Pack: Codable {
        let id: String
        let name: String
        let version: String
        let kind: String
        let authors: [String]?
        let description: String?
        let license: String?
        let permissions: [String]?
        let dir: String
    }

    struct ErrorEntry: Codable {
        let dir: String
        let error: String
    }

    let packs: [Pack]
    let errors: [ErrorEntry]
}

enum PluginStore {
    /// 插件根目录：~/Library/Application Support/Liana/plugins
    static var pluginsDir: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Liana/plugins", isDirectory: true)
    }

    /// 调内核扫描（校验清单 + 权限白名单），坏包在 errors 里给出原因。
    static func scan() -> PluginCatalog {
        let dir = pluginsDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let result = dir.path.withCString { liana_plugin_scan_json($0) }
        guard let result else { return PluginCatalog(packs: [], errors: []) }
        defer { liana_free_string(result) }
        guard
            let data = String(cString: result).data(using: .utf8),
            let catalog = try? JSONDecoder().decode(PluginCatalog.self, from: data)
        else { return PluginCatalog(packs: [], errors: []) }
        return catalog
    }

    static func packs(kind: String, in catalog: PluginCatalog) -> [PluginCatalog.Pack] {
        catalog.packs.filter { $0.kind == kind }
    }

    /// 已下线的内置示例形象包：升级时从用户插件目录清理，避免菜单里残留。
    private static let retiredPackIds: [String] = [
        "pet-neko", "pet-orange-cat", "pet-oriental-beauty",
        "pet-robot", "pet-shiba", "pet-western-beauty",
    ]

    /// 把 app 内随包分发的示例插件（Resources/Plugins/*）seeding 到用户插件目录。
    /// 未安装则复制；已安装但版本不同则更新（用户自建包不受影响）。
    static func seedBundledPacks() {
        pruneRetiredPacks()
        guard let resources = Bundle.main.resourceURL else { return }
        let source = resources.appendingPathComponent("Plugins", isDirectory: true)
        let fm = FileManager.default
        try? fm.createDirectory(at: pluginsDir, withIntermediateDirectories: true)
        guard let items = try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return
        }
        for item in items where item.hasDirectoryPath {
            let target = pluginsDir.appendingPathComponent(item.lastPathComponent, isDirectory: true)
            if !fm.fileExists(atPath: target.path) {
                try? fm.copyItem(at: item, to: target)
                continue
            }
            if bundledVersion(of: item) != bundledVersion(of: target) {
                try? fm.removeItem(at: target)
                try? fm.copyItem(at: item, to: target)
            }
        }
    }

    private static func pruneRetiredPacks() {
        let fm = FileManager.default
        for id in retiredPackIds {
            let dir = pluginsDir.appendingPathComponent(id, isDirectory: true)
            if fm.fileExists(atPath: dir.path) {
                try? fm.removeItem(at: dir)
            }
        }
    }

    private static func bundledVersion(of dir: URL) -> String? {
        let url = dir.appendingPathComponent("plugin.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json["version"] as? String
    }
}

// MARK: - 皮肤管理

/// 激活皮肤的管理：id 存 UserDefaults（"" = 跟随系统）。
enum ThemeStore {
    static let changedNotification = Notification.Name("LianaThemeChanged")
    private static let activeKey = "LianaSkinId"

    static var activeId: String {
        get { UserDefaults.standard.string(forKey: activeKey) ?? "" }
        set {
            UserDefaults.standard.set(newValue, forKey: activeKey)
            NotificationCenter.default.post(name: changedNotification, object: nil)
        }
    }

    static func availableSkins() -> [PluginCatalog.Pack] {
        PluginStore.packs(kind: "skin", in: PluginStore.scan())
    }

    static func activeTheme() -> CandidateTheme {
        guard !activeId.isEmpty else { return .system }
        let dir = PluginStore.pluginsDir.appendingPathComponent(activeId, isDirectory: true)
        return CandidateTheme.load(from: dir) ?? .system
    }
}
