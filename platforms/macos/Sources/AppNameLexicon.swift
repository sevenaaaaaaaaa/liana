import AppKit

/// 本机应用名词包：把已安装应用的中文名（哔哩哔哩、钉钉、飞书、活动监视器…）写进
/// `~/Library/Application Support/Liana/dicts/apps.tsv`，内核加载时叠加到基础词库（自动注音）。
///
/// 只读应用包里的名字（文件系统上公开的信息），不读应用数据、不联网；内容没变就不重写，
/// 不会让内核的词库缓存失效。
enum AppNameLexicon {
    static let directory = NSHomeDirectory() + "/Library/Application Support/Liana/dicts"
    private static let file = directory + "/apps.tsv"
    /// 与官方词包的 C 档同尺度：常用但不压过同音的普通词
    private static let freq = 3000

    private static let searchDirs = [
        "/Applications", "/Applications/Utilities",
        "/System/Applications", "/System/Applications/Utilities",
        NSHomeDirectory() + "/Applications",
    ]
    private static let extraApps = ["/System/Library/CoreServices/Finder.app"]
    private static let chineseLocales = ["zh-Hans", "zh_CN", "zh-Hans-CN", "zh_Hans", "zh-CN"]

    /// 后台刷新一次（启动时、之后每 6 小时）。
    static func refresh() {
        DispatchQueue.global(qos: .utility).async {
            let names = collectNames()
            let body = "# 松萝 · 本机应用名词包（自动生成，勿手改）\n"
                + names.sorted().map { "\($0)\t\t\(freq)" }.joined(separator: "\n") + "\n"
            if (try? String(contentsOfFile: file, encoding: .utf8)) == body { return }
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try? body.write(toFile: file, atomically: true, encoding: .utf8)
            NSLog("松萝: 应用名词包已更新（\(names.count) 个）")
        }
    }

    static func startPeriodicRefresh() {
        refresh()
        Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in refresh() }
    }

    static func collectNames() -> Set<String> {
        let fm = FileManager.default
        var apps = extraApps
        for dir in searchDirs {
            let items = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
            apps += items.filter { $0.hasSuffix(".app") }.map { dir + "/" + $0 }
        }
        var names = Set<String>()
        for path in apps {
            var candidates = [fm.displayName(atPath: path)]
            if let bundle = Bundle(path: path) { candidates += chineseNames(of: bundle) }
            for raw in candidates {
                let name = raw.hasSuffix(".app") ? String(raw.dropLast(4)) : raw
                if isTypeable(name) { names.insert(name) }
            }
        }
        return names
    }

    /// 应用包里的简体中文名：InfoPlist.strings（zh-Hans.lproj 等）或系统应用的 InfoPlist.loctable。
    private static func chineseNames(of bundle: Bundle) -> [String] {
        var out: [String] = []
        let keys = ["CFBundleDisplayName", "CFBundleName"]
        for locale in chineseLocales {
            if let path = bundle.path(forResource: "InfoPlist", ofType: "strings", inDirectory: nil, forLocalization: locale),
               let dict = NSDictionary(contentsOfFile: path) as? [String: Any] {
                out += keys.compactMap { dict[$0] as? String }
            }
        }
        if let path = bundle.path(forResource: "InfoPlist", ofType: "loctable"),
           let table = NSDictionary(contentsOfFile: path) as? [String: Any] {
            for locale in chineseLocales {
                if let dict = table[locale] as? [String: Any] {
                    out += keys.compactMap { dict[$0] as? String }
                }
            }
        }
        return out
    }

    /// 能用拼音整个打出来的名字：全是汉字、2～8 个字。
    private static func isTypeable(_ name: String) -> Bool {
        let count = name.count
        guard (2...8).contains(count) else { return false }
        return name.unicodeScalars.allSatisfy { (0x3400...0x9FFF).contains($0.value) || (0xF900...0xFAFF).contains($0.value) }
    }
}
