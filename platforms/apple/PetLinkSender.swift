import Foundation
import Network

final class PetLinkSender {
    var onStatus: ((String) -> Void)?
    var onClipboard: ((String?) -> Void)?
    private var clipboardID: String?
    private var clipboardSupported = false
    var onReady: (() -> Void)?
    var onSaved: ((String) -> Void)?
    var onProgress: ((Double) -> Void)?
    var onDisconnected: (() -> Void)?
    var onFailure: (() -> Void)?
    private(set) var ready = false
    private var browser: NWBrowser?
    private var channel: PetLinkChannel?
    private var discoveryTimeout: DispatchWorkItem?
    private var file: FileHandle?
    private var currentID: String?
    private var size: Int64 = 0
    private var sent: Int64 = 0
    private var scopedURL: URL?
    private var hasScope = false
    private let deviceID: UUID
    private let deviceName: String

    init(deviceID: UUID, deviceName: String) { self.deviceID = deviceID; self.deviceName = String(deviceName.prefix(80)) }
    private func status(_ message: String) { DispatchQueue.main.async { [weak self] in self?.onStatus?(message) } }
    func connect(profile: PetLink.Profile, endpoint: NWEndpoint? = nil) {
        PetLink.queue.async { [weak self] in
            guard let self else { return }
            self.disconnectNow()
            self.status("正在寻找 \(profile.name)…")
            if let endpoint { self.open(endpoint, profile: profile); return }
            let browser = NWBrowser(for: .bonjour(type: PetLink.serviceType, domain: "local."), using: .tcp)
            self.browser = browser
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                guard let self, self.channel == nil else { return }
                if let result = results.first(where: { if case .service(let name, _, _, _) = $0.endpoint { return name == profile.service }; return false }) {
                    self.discoveryTimeout?.cancel(); self.browser?.cancel(); self.browser = nil
                    self.open(result.endpoint, profile: profile)
                }
            }
            browser.stateUpdateHandler = { [weak self] state in if case .failed(let error) = state { self?.status("无法发现 Mac：\(error.localizedDescription)。请检查本地网络权限。"); self?.disconnectNow() } }
            browser.start(queue: PetLink.queue)
            let timeout = DispatchWorkItem { [weak self] in self?.status("未找到 Mac，请开启桌宠接收并保持同一局域网，再点连接。"); self?.disconnectNow() }
            self.discoveryTimeout = timeout
            PetLink.queue.asyncAfter(deadline: .now() + 15, execute: timeout)
        }
    }
    private func open(_ endpoint: NWEndpoint, profile: PetLink.Profile) {
        let channel = PetLinkChannel(NWConnection(to: endpoint, using: PetLink.parameters(key: profile.key)))
        self.channel = channel
        channel.onReady = { [weak self, weak channel] in
            guard let self else { return }
            self.status("加密连接已建立，首次连接请在 Mac 允许配对。")
            channel?.json(["kind": "hello", "version": 1, "device": self.deviceID.uuidString, "name": self.deviceName])
        }
        channel.onClose = { [weak self, weak channel] reason in
            guard let self, self.channel === channel else { return }
            self.ready = false
            self.clearFile()
            self.channel = nil
            self.status(reason)
            DispatchQueue.main.async { [weak self] in self?.onDisconnected?() }
        }
        channel.onFrame = { [weak self] kind, data in self?.receive(kind, data) }
        channel.start()
    }
    func disconnect(silent: Bool = false) { PetLink.queue.async { [self] in disconnectNow(); if !silent { status("已断开连接。") } } }
    private func disconnectNow() {
        let wasActive = channel != nil || browser != nil || ready
        discoveryTimeout?.cancel(); browser?.cancel(); browser = nil
        let old = channel; channel = nil; old?.close("已断开连接。")
        ready = false; clipboardID = nil; clipboardSupported = false; clearFile()
        if wasActive { DispatchQueue.main.async { [weak self] in self?.onDisconnected?() } }
    }
    private func clearFile() {
        try? file?.close(); file = nil; currentID = nil
        if hasScope { scopedURL?.stopAccessingSecurityScopedResource() }
        scopedURL = nil; hasScope = false
    }
    func send(_ url: URL) {
        PetLink.queue.async { [weak self] in
            guard let self, self.ready, self.currentID == nil, self.clipboardID == nil, let channel = self.channel else {
                self?.status("请先连接 Mac，或等待当前文件完成。")
                DispatchQueue.main.async { [weak self] in self?.onFailure?() }
                return
            }
            do {
                self.hasScope = url.startAccessingSecurityScopedResource(); self.scopedURL = url
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values.isRegularFile == true, let count = values.fileSize, count <= PetLink.maxFileSize else { throw PetLink.Failure.message("仅支持不超过 200MB 的普通文件。") }
                let name = try PetLink.safeName(url.lastPathComponent)
                let digest = try PetLink.sha256(url)
                self.file = try FileHandle(forReadingFrom: url)
                let id = UUID().uuidString
                self.currentID = id; self.size = Int64(count); self.sent = 0
                self.status("准备发送 \(name)…")
                channel.json(["kind": "offer", "id": id, "name": name, "size": count, "sha256": digest])
            } catch { self.clearFile(); self.status(error.localizedDescription); DispatchQueue.main.async { [weak self] in self?.onFailure?() } }
        }
    }
    /// A user-triggered foreground exchange; no background clipboard observation.
    func clipboard(text: String? = nil) {
        PetLink.queue.async { [weak self] in
            guard let self else { return }
            guard self.ready, self.clipboardSupported, self.currentID == nil, self.clipboardID == nil, let channel = self.channel else {
                self.status("请连接支持剪贴板同步的新版 Mac 松萝，并等待当前传输完成。")
                DispatchQueue.main.async { [weak self] in self?.onFailure?() }; return
            }
            let id = UUID().uuidString
            var object: [String: Any] = ["kind": text == nil ? "clipboardPull" : "clipboardPush", "id": id]
            if let text { object["text"] = text }
            guard (text?.utf8.count ?? 0) <= 4000, let encoded = try? JSONSerialization.data(withJSONObject: object), encoded.count <= 8192 else {
                self.status("剪贴板文字过长，单次最多 4KB，请改用文件传输。")
                DispatchQueue.main.async { [weak self] in self?.onFailure?() }; return
            }
            self.clipboardID = id; channel.json(object)
            PetLink.queue.asyncAfter(deadline: .now() + 15) { [weak self] in
                guard let self, self.clipboardID == id else { return }
                self.clipboardID = nil; self.status("剪贴板同步超时，请检查 Mac 权限与网络后重试。")
                DispatchQueue.main.async { [weak self] in self?.onFailure?() }
            }
        }
    }
    private func receive(_ kind: UInt8, _ data: Data) {
        guard kind == 1, data.count <= 8192, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let message = object["kind"] as? String else { channel?.close("Mac 返回了无效消息。"); return }
        if message == "ready" {
            clipboardSupported = object["clipboard"] as? Int == 1
            ready = true; status("已连接，可选择文件发送到 Mac 桌宠。")
            DispatchQueue.main.async { [weak self] in self?.onReady?() }
        } else if message == "clipboardValue", let text = object["text"] as? String, text.utf8.count <= 4000, object["id"] as? String == clipboardID, clipboardID != nil {
            clipboardID = nil; status("已接收 Mac 剪贴板文字。")
            DispatchQueue.main.async { [weak self] in self?.onClipboard?(text) }
        } else if message == "clipboardSaved", object["id"] as? String == clipboardID, clipboardID != nil {
            clipboardID = nil; status("文字已发送到 Mac 剪贴板。")
            DispatchQueue.main.async { [weak self] in self?.onClipboard?(nil) }
        } else if message == "clipboardError", object["id"] as? String == clipboardID, clipboardID != nil {
            clipboardID = nil; status(object["message"] as? String ?? "Mac 未允许剪贴板同步。")
            DispatchQueue.main.async { [weak self] in self?.onFailure?() }
        } else if message == "accept", object["id"] as? String == currentID, currentID != nil { nextChunk() }
        else if message == "saved", object["id"] as? String == currentID, let name = object["name"] as? String {
            clearFile(); status("Mac 已校验并保存：\(name)")
            DispatchQueue.main.async { [weak self] in self?.onSaved?(name) }
        } else if message == "error" { channel?.close(object["message"] as? String ?? "Mac 无法接收文件。") }
        else { channel?.close("Mac 传输状态无效。") }
    }
    private func nextChunk() {
        guard let file, let id = currentID, let channel else { return }
        do {
            let block = try file.read(upToCount: 65_536) ?? Data()
            if block.isEmpty { channel.json(["kind": "end", "id": id]); status("正在等待 Mac 校验和保存…"); return }
            guard sent + Int64(block.count) <= size else { throw PetLink.Failure.message("发送中文件发生变化，请重新选择。") }
            channel.send(2, block) { [weak self] in
                guard let self else { return }
                self.sent += Int64(block.count)
                let value = self.size == 0 ? 1 : Double(self.sent) / Double(self.size)
                DispatchQueue.main.async { [weak self] in self?.onProgress?(value) }
                self.nextChunk()
            }
        } catch { channel.close(error.localizedDescription) }
    }
}
