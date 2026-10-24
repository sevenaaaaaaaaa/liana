import AppKit
import SwiftUI

// MARK: - 功能面板（⌃` 呼出）
//
// 把埋在菜单深处的功能摆到眼前：截图学习、语音、同传、桌宠、喂食、剪切板……
// 面板不激活本进程：焦点留在用户正在打字的应用里，语音/同传直接落到当前输入框。
// 键盘：数字 1–9 直达，Esc 关闭（由输入控制器转发按键）。

final class QuickPanelModel: ObservableObject {
    @Published var mode: String = LianaMode.pinyin.rawValue
    @Published var listening = false
    @Published var interpret: String?
    @Published var petOn = PetWindowController.isEnabled
    @Published var media: MediaController.NowPlaying?
    @Published var volume: Int?
}

struct QuickTile: Identifiable {
    let id: LianaActions.ID
    let key: Int
    let title: String
    let subtitle: String
    let symbol: String
    let color: Color
}

final class QuickPanelController {
    static let shared = QuickPanelController()

    private let model = QuickPanelModel()
    private var panel: LianaKeyablePanel?
    private var outsideMonitor: Any?
    private static let size = NSSize(width: 600, height: 552)

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle(near caret: NSRect?, mode: String, listening: Bool, interpret: String?) {
        if isVisible {
            hide()
        } else {
            show(near: caret, mode: mode, listening: listening, interpret: interpret)
        }
    }

    func show(near caret: NSRect?, mode: String, listening: Bool, interpret: String?) {
        model.mode = mode
        model.listening = listening
        model.interpret = interpret
        model.petOn = PetWindowController.isEnabled
        refreshMedia()
        let panel = ensurePanel()
        LianaGlassContainer.position(panel, near: caret)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            panel.animator().alphaValue = 1
        }
        installOutsideMonitor()
        UserDefaults.standard.set(true, forKey: "LianaQuickPanelSeen")
    }

    /// 拉当前曲目与音量（AppleScript 离主线程，回调回主线程刷新）。
    func refreshMedia() {
        DispatchQueue.global(qos: .userInitiated).async {
            let np = MediaController.shared.nowPlaying()
            let volume = MediaController.shared.outputVolume()
            DispatchQueue.main.async {
                self.model.media = np
                self.model.volume = volume
            }
        }
    }

    func hide() {
        removeOutsideMonitor()
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
    }

    /// 数字键直达：返回 true 表示按键已被面板消费。
    @discardableResult
    func trigger(key: Int) -> Bool {
        guard let tile = Self.tiles.first(where: { $0.key == key }) else { return false }
        run(resolvedAction(tile))
        return true
    }

    /// 进行中的同传再点一次 = 关闭。
    func resolvedAction(_ tile: QuickTile) -> LianaActions.ID {
        switch tile.id {
        case .interpretEn where model.interpret == "en": return .interpretOff
        case .interpretJa where model.interpret == "ja": return .interpretOff
        default: return tile.id
        }
    }

    func switchMode(_ id: String) {
        model.mode = id
        NotificationCenter.default.post(
            name: .lianaControllerAction, object: nil, userInfo: ["action": "mode:\(id)"]
        )
    }

    func run(_ id: LianaActions.ID) {
        hide()
        // 截图要等面板真正消失再开始，否则面板会被框进截图
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            LianaActions.perform(id)
        }
    }

    static let tiles: [QuickTile] = [
        QuickTile(id: .screenshotLearn, key: 1, title: "截图学习", subtitle: "框选屏幕，学会新词",
                  symbol: "text.viewfinder", color: LianaDesign.pine),
        QuickTile(id: .voice, key: 2, title: "语音输入", subtitle: "边说边落字",
                  symbol: "mic.fill", color: Color(red: 0.95, green: 0.33, blue: 0.36)),
        QuickTile(id: .interpretEn, key: 3, title: "同传 · 英文", subtitle: "说中文，打出英文",
                  symbol: "globe", color: LianaDesign.brand),
        QuickTile(id: .interpretJa, key: 4, title: "同传 · 日文", subtitle: "说中文，打出日文",
                  symbol: "globe.asia.australia.fill", color: Color(red: 0.55, green: 0.42, blue: 0.95)),
        QuickTile(id: .pet, key: 5, title: "桌宠", subtitle: "陪你打字",
                  symbol: "pawprint.fill", color: Color(red: 0.98, green: 0.62, blue: 0.22)),
        QuickTile(id: .feed, key: 6, title: "喂它一段", subtitle: "文档/聊天记录进词库",
                  symbol: "doc.text.fill", color: Color(red: 0.18, green: 0.64, blue: 0.78)),
        QuickTile(id: .clipboard, key: 7, title: "剪切板", subtitle: "历史记录，加密保存",
                  symbol: "doc.on.clipboard.fill", color: Color(red: 0.45, green: 0.50, blue: 0.58)),
        QuickTile(id: .stats, key: 8, title: "昨日总结", subtitle: "速度、准确率、省键",
                  symbol: "chart.bar.fill", color: Color(red: 0.30, green: 0.72, blue: 0.40)),
        QuickTile(id: .shelfCapture, key: 9, title: "截图暂存", subtitle: "框选直接进暂存架",
                  symbol: "camera.on.rectangle.fill", color: Color(red: 0.85, green: 0.55, blue: 0.30)),
        QuickTile(id: .shelfOpen, key: 10, title: "暂存架", subtitle: "临时截图/文件 · 7 天自动清",
                  symbol: "archivebox.fill", color: Color(red: 0.60, green: 0.55, blue: 0.85)),
    ]

    // MARK: - 内部

    private func ensurePanel() -> LianaKeyablePanel {
        if let panel { return panel }
        let host = LianaFirstMouseHostingView(rootView: QuickPanelView(model: model, controller: self))
        host.frame = NSRect(origin: .zero, size: Self.size)
        let panel = LianaGlassContainer.makePanel(size: Self.size, cornerRadius: LianaDesign.radiusLarge, content: host)
        self.panel = panel
        return panel
    }

    private func installOutsideMonitor() {
        removeOutsideMonitor()
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, let panel = self.panel else { return }
            if !panel.frame.contains(NSEvent.mouseLocation) {
                self.hide()
            }
        }
    }

    private func removeOutsideMonitor() {
        if let outsideMonitor {
            NSEvent.removeMonitor(outsideMonitor)
        }
        outsideMonitor = nil
    }
}

struct QuickPanelView: View {
    @ObservedObject var model: QuickPanelModel
    let controller: QuickPanelController

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)
    private let modes: [(String, String)] = [
        (LianaMode.pinyin.rawValue, "拼音"),
        (LianaMode.flypy.rawValue, "双拼"),
        (LianaMode.en.rawValue, "English"),
        (LianaMode.ja.rawValue, "日本語"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(QuickPanelController.tiles) { tile in
                    QuickTileButton(tile: tile, active: isActive(tile), subtitle: subtitle(for: tile)) {
                        controller.run(controller.resolvedAction(tile))
                    }
                }
            }
            mediaRow
            footer
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// 正在播放：有曲目或拿得到音量才出现。操作不关面板，方便连续调。
    @ViewBuilder
    private var mediaRow: some View {
        if model.media != nil || model.volume != nil {
            HStack(spacing: 10) {
                LianaIconBadge(symbol: "music.note", color: Color(red: 0.95, green: 0.45, blue: 0.65), size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.media?.title ?? "没有在播的音乐")
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                    Text([model.media?.artist, model.media?.app].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                mediaButton("backward.end.fill", "上一首") { MediaActions.perform(.previous) }
                mediaButton(model.media?.playing == true ? "pause.fill" : "play.fill", "播放 / 暂停") {
                    MediaActions.perform(.toggle)
                }
                mediaButton("forward.end.fill", "下一首") { MediaActions.perform(.next) }
                Rectangle().fill(Color.primary.opacity(0.10)).frame(width: 1, height: 20)
                mediaButton("speaker.minus.fill", "音量 −") { MediaActions.perform(.volumeDown) }
                Text(model.volume.map { "\($0)" } ?? "–")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(width: 26)
                mediaButton("speaker.plus.fill", "音量 +") { MediaActions.perform(.volumeUp) }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.05)))
        }
    }

    private func mediaButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { controller.refreshMedia() }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.primary.opacity(0.07)))
        }
        .buttonStyle(.plain)
        .help(label)
    }

    private var header: some View {
        HStack(spacing: 10) {
            LianaIconBadge(symbol: "leaf.fill", color: LianaDesign.pine, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text("松萝 · 功能面板")
                    .font(.system(size: 15, weight: .semibold))
                Text("数字键直达 · Esc 关闭 · 随时按 ⌃` 呼出")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                controller.run(.settings)
            } label: {
                Label("设置", systemImage: "gearshape.fill")
                    .font(.system(size: 12, weight: .medium))
            }
            .lianaGlassButton()
            .controlSize(.small)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text("输入模式")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            ForEach(modes, id: \.0) { item in
                Button {
                    controller.switchMode(item.0)
                } label: {
                    Text(item.1)
                        .font(.system(size: 12, weight: model.mode == item.0 ? .semibold : .regular))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(model.mode == item.0 ? LianaDesign.brand.opacity(0.22) : Color.primary.opacity(0.06))
                        )
                        .foregroundStyle(model.mode == item.0 ? LianaDesign.brand : Color.primary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            if model.interpret != nil {
                Button {
                    controller.run(.interpretOff)
                } label: {
                    Label("关闭同传", systemImage: "xmark.circle.fill")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func isActive(_ tile: QuickTile) -> Bool {
        switch tile.id {
        case .voice: return model.listening && model.interpret == nil
        case .interpretEn: return model.interpret == "en"
        case .interpretJa: return model.interpret == "ja"
        case .pet: return model.petOn
        default: return false
        }
    }

    private func subtitle(for tile: QuickTile) -> String {
        switch tile.id {
        case .voice where model.listening && model.interpret == nil: return "正在听 · 点击停止"
        case .interpretEn where model.interpret == "en": return "进行中 · 点击关闭"
        case .interpretJa where model.interpret == "ja": return "进行中 · 点击关闭"
        case .pet: return model.petOn ? "已出现 · 点击收起" : "点击召唤"
        default: return tile.subtitle
        }
    }
}

struct QuickTileButton: View {
    let tile: QuickTile
    let active: Bool
    let subtitle: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    LianaIconBadge(symbol: tile.symbol, color: tile.color, size: 34)
                    Spacer()
                    Text("\(tile.key)")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Color.primary.opacity(0.07)))
                }
                Spacer(minLength: 0)
                Text(tile.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(active ? tile.color : Color.secondary)
                    .lineLimit(1)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 112, maxHeight: 112, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(active ? tile.color.opacity(0.20) : Color.primary.opacity(hovering ? 0.10 : 0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(active ? tile.color.opacity(0.65) : Color.primary.opacity(0.06), lineWidth: active ? 1.2 : 0.6)
            )
            .scaleEffect(hovering ? 1.02 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.8), value: hovering)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
