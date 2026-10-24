import AppKit

// MARK: - 临时暂存架
//
// 临时截图、临时文件的落脚点：不污染桌面和下载。
// 位置 ~/Library/Application Support/Liana/shelf/，就是一个普通 Finder 文件夹，
// 可以直接往里拖文件；7 天没动过的自动清掉（每次打开暂存架和启动输入法时各清一次）。

enum StagingShelf {
    static let maxAgeDays = 7

    static var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Liana/shelf", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// 清掉超过 7 天没动过的文件。
    static func clean() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        let cutoff = Date().addingTimeInterval(-Double(maxAgeDays) * 86400)
        for file in files where file != dir {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if modified < cutoff {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    static func open() {
        clean()
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }

    /// 交互框选截图，直接落进暂存架（不进桌面、不弹保存框）。
    static func captureScreenshot() {
        clean()
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmmss"
        let path = dir.appendingPathComponent("截图-\(df.string(from: Date())).png").path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // -i 交互框选（空格切窗口），-x 不播快门声
        process.arguments = ["-i", "-x", path]
        process.terminationHandler = { _ in
            DispatchQueue.main.async {
                guard FileManager.default.fileExists(atPath: path) else { return }  // Esc 取消
                GlassToast.shared.show("截图已存入暂存架（7 天后自动清）", symbol: "camera.fill", duration: 3)
                PetWindowController.shared.notify("notify_ok")
            }
        }
        do {
            try process.run()
        } catch {
            GlassToast.shared.show("无法启动截图：\(error.localizedDescription)", symbol: "exclamationmark.triangle.fill", duration: 5)
        }
    }

    /// 权限中心展示用：暂存架里现有几个文件。
    static func itemCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: dir.path).filter { !$0.hasPrefix(".") }.count) ?? 0
    }
}
