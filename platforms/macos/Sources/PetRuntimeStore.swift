import Foundation

/// 桌宠渲染运行时管理（VRM / Live2D 共用）。
///
/// - VRM：把 app 内置的 three.js/three-vrm 运行时复制到用户目录，并按形象包准备模型。
/// - Live2D（方案 A：Bring-Your-Own）：只随包分发我们自己的 HTML/JS 与 MIT 依赖，
///   **不分发** Live2D Cubism Core（专有）与模型；用户把 Core 放进 `live2d-user/core/`，
///   由本 Store 合入运行时目录（不同步、不覆盖）。见 ADR-0009。
enum PetRuntimeStore {
    // MARK: - 运行时根目录

    /// `~/Library/Application Support/Liana/pet-runtime`（随包同步）
    static var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Liana/pet-runtime", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private static var bundledDir: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("PetRuntime", isDirectory: true)
    }

    private static func marker(_ dir: URL) -> String? {
        try? String(contentsOf: dir.appendingPathComponent("VERSION"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 确保运行时与 app 内置版本一致（VERSION 不同则整目录更新）。
    @discardableResult
    static func ensure() -> URL {
        let fm = FileManager.default
        guard let bundled = bundledDir, fm.fileExists(atPath: bundled.path) else { return dir }
        if marker(dir) != marker(bundled) || !fm.fileExists(atPath: dir.appendingPathComponent("pet.html").path) {
            try? fm.removeItem(at: dir)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            if let items = try? fm.contentsOfDirectory(at: bundled, includingPropertiesForKeys: [.isDirectoryKey]) {
                for item in items {
                    try? fm.copyItem(at: item, to: dir.appendingPathComponent(item.lastPathComponent))
                }
            }
        }
        return dir
    }

    // MARK: - VRM

    /// 为 VRM 形象包准备模型，返回相对运行时目录的路径（供 pet.html?model= 使用）。
    static func modelPath(for packId: String, entry: String?) -> String? {
        let fm = FileManager.default
        let runtime = ensure()
        let models = runtime.appendingPathComponent("models", isDirectory: true)
        try? fm.createDirectory(at: models, withIntermediateDirectories: true)
        let destination = models.appendingPathComponent("\(packId).vrm")
        let source: URL?
        if let entry, !entry.isEmpty {
            source = PluginStore.pluginsDir
                .appendingPathComponent(packId, isDirectory: true)
                .appendingPathComponent(entry)
        } else {
            source = runtime.appendingPathComponent("sample.vrm")   // 内置样例模型
        }
        guard let source, fm.fileExists(atPath: source.path) else { return nil }
        // 源比目标新才复制
        let srcDate = (try? fm.attributesOfItem(atPath: source.path)[.modificationDate] as? Date) ?? nil
        let dstDate = (try? fm.attributesOfItem(atPath: destination.path)[.modificationDate] as? Date) ?? nil
        if dstDate == nil || (srcDate != nil && dstDate! < srcDate!) {
            try? fm.removeItem(at: destination)
            try? fm.copyItem(at: source, to: destination)
        }
        return "models/\(packId).vrm"
    }

    // MARK: - 纸偶（puppet）

    /// 运行时内 puppet 子目录（pet-puppet.html/js + 预置动作库 + 形象包副本）。
    static var puppetDir: URL {
        dir.appendingPathComponent("puppet", isDirectory: true)
    }

    @discardableResult
    static func ensurePuppet() -> URL {
        ensure()
        return puppetDir
    }

    /// 把纸偶形象包复制进运行时（WebKit 只能读一个根目录）。包很小，每次整体刷新，
    /// 保证形象工坊保存后立即生效。返回相对 puppet 目录的路径（供 ?pack= 使用）。
    static func puppetPackPath(for packId: String) -> String? {
        let fm = FileManager.default
        let source = PluginStore.pluginsDir.appendingPathComponent(packId, isDirectory: true)
        guard fm.fileExists(atPath: source.appendingPathComponent("pet.json").path) else { return nil }
        let packs = ensurePuppet().appendingPathComponent("packs", isDirectory: true)
        let destination = packs.appendingPathComponent(packId, isDirectory: true)
        try? fm.removeItem(at: destination)
        try? fm.createDirectory(at: packs, withIntermediateDirectories: true)
        guard (try? fm.copyItem(at: source, to: destination)) != nil else { return nil }
        return "packs/\(packId)/"
    }

    /// 形象工坊实时预览用的临时包目录（不进插件目录、不出现在形象列表）。
    static var puppetPreviewDir: URL {
        ensurePuppet().appendingPathComponent("packs/_preview", isDirectory: true)
    }

    // MARK: - Live2D（方案 A：自带运行时 + 模型）

    /// 用户自备 Cubism Core 的落点：`~/Library/Application Support/Liana/live2d-user/core/`。
    /// 该目录**不随包同步、不覆盖**，用户放入 `live2dcubismcore.min.js`（可从 Live2D 官网 SDK 取得）。
    static var userLive2DCoreDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Liana/live2d-user/core", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// 运行时内 live2d 子目录（我们的 pet-live2d.html/js + MIT vendor + 合入的 Core）。
    static var live2DDir: URL {
        dir.appendingPathComponent("live2d", isDirectory: true)
    }

    /// 同步 live2d 运行时（含 MIT 依赖），并把用户自备的 Core 合入运行时目录。
    /// WebKit 只允许一个读取根目录，所以 Core 必须落在 live2d 运行时目录内。
    @discardableResult
    static func ensureLive2D() -> URL {
        ensure()
        mergeUserCore()
        return live2DDir
    }

    /// Cubism Core 是否就绪（运行时目录内存在 `live2dcubismcore.min.js`）。
    static func live2DCoreAvailable() -> Bool {
        let core = live2DDir.appendingPathComponent("live2dcubismcore.min.js")
        return FileManager.default.fileExists(atPath: core.path)
    }

    /// 把用户自备的 Core 文件复制进运行时目录（每次 ensureLive2D 调用；不反向同步）。
    private static func mergeUserCore() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: userLive2DCoreDir.path),
              let items = try? fm.contentsOfDirectory(at: userLive2DCoreDir, includingPropertiesForKeys: nil)
        else { return }
        try? fm.createDirectory(at: live2DDir, withIntermediateDirectories: true)
        for item in items where !item.hasDirectoryPath {
            let dst = live2DDir.appendingPathComponent(item.lastPathComponent)
            let srcDate = (try? fm.attributesOfItem(atPath: item.path)[.modificationDate] as? Date) ?? nil
            let dstDate = (try? fm.attributesOfItem(atPath: dst.path)[.modificationDate] as? Date) ?? nil
            if dstDate == nil || (srcDate != nil && dstDate! < srcDate!) {
                try? fm.removeItem(at: dst)
                try? fm.copyItem(at: item, to: dst)
            }
        }
    }

    /// 为 Live2D 形象包准备模型：把整个模型目录复制进运行时（多文件：model3.json + 贴图/moc3/motion）。
    /// 返回相对 live2d 运行时目录的 entry 路径（供 pet-live2d.html?model= 使用）。
    static func live2DModelPath(for packId: String, entry: String?) -> String? {
        let fm = FileManager.default
        _ = ensureLive2D()
        let source = PluginStore.pluginsDir.appendingPathComponent(packId, isDirectory: true)
        guard fm.fileExists(atPath: source.path) else { return nil }
        let models = live2DDir.appendingPathComponent("models", isDirectory: true)
        let destination = models.appendingPathComponent(packId, isDirectory: true)
        let srcDate = (try? fm.attributesOfItem(atPath: source.path)[.modificationDate] as? Date) ?? nil
        let dstDate = (try? fm.attributesOfItem(atPath: destination.path)[.modificationDate] as? Date) ?? nil
        if dstDate == nil || (srcDate != nil && dstDate! < srcDate!) {
            try? fm.removeItem(at: destination)
            try? fm.createDirectory(at: models, withIntermediateDirectories: true)
            try? fm.copyItem(at: source, to: destination)
        }
        let entryName = (entry?.isEmpty == false ? entry! : "model.model3.json")
        let rel = "models/\(packId)/\(entryName)"
        guard fm.fileExists(atPath: live2DDir.appendingPathComponent(rel).path) else { return nil }
        return rel
    }
}
