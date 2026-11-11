import Foundation
import Network
import CryptoKit

final class PetLinkReceiver {
    let profile: PetLink.Profile
    let directory: URL
    var authorize: ((UUID, String, @escaping (Bool) -> Void) -> Void)?
    var onStatus: ((String) -> Void)?
    var onReceived: ((URL, String) -> Void)?
    private(set) var port: NWEndpoint.Port?
    private var listener: NWListener?
    private var peers: [UUID: Peer] = [:]
    private let trustedKey: String
    private var trusted: Set<String>

    private final class Peer {
        let channel: PetLinkChannel
        var name = "iPhone"
        var approved = false
        var awaitingApproval = false
        var file: FileHandle?
        var temporary: URL?
        var destination: URL?
        var fileID = ""
        var remaining: Int64 = 0
        var expectedHash = ""
        var hash = SHA256()
        init(_ channel: PetLinkChannel) { self.channel = channel }
        func clean() { try? file?.close(); file = nil; if let temporary { try? FileManager.default.removeItem(at: temporary) }; temporary = nil }
        deinit { clean() }
    }

    init(profile: PetLink.Profile, directory: URL, trustNamespace: String = "PetLink.trusted") {
        self.profile = profile; self.directory = directory
        trustedKey = trustNamespace + "." + profile.id.uuidString
        trusted = Set(UserDefaults.standard.stringArray(forKey: trustedKey) ?? [])
    }
    func start() {
        PetLink.queue.async { [weak self] in
            guard let self, self.listener == nil else { return }
            do {
                try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
                let listener = try NWListener(using: PetLink.parameters(key: self.profile.key), on: .any)
                self.listener = listener
                listener.service = NWListener.Service(name: self.profile.service, type: PetLink.serviceType)
                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    guard let self else { return }
                    switch state {
                    case .ready: self.port = listener?.port; self.status("等待 iPhone，保持两端在同一局域网。")
                    case .failed(let error): self.status("接收服务失败：\(error.localizedDescription)"); self.stop()
                    default: break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                listener.start(queue: PetLink.queue)
            } catch { self.status(error.localizedDescription) }
        }
    }
    func stop() {
        PetLink.queue.async { [self] in
            self.listener?.cancel(); self.listener = nil; self.port = nil
            for peer in Array(self.peers.values) { peer.channel.close("已停止接收。"); peer.clean() }
            self.peers.removeAll()
            self.status("已停止接收。")
        }
    }
    private func status(_ text: String) { DispatchQueue.main.async { [weak self] in self?.onStatus?(text) } }
    private func accept(_ connection: NWConnection) {
        guard peers.count < 4 else { connection.cancel(); return }
        let token = UUID()
        let peer = Peer(PetLinkChannel(connection))
        peers[token] = peer
        peer.channel.onClose = { [weak self, weak peer] _ in peer?.clean(); self?.peers.removeValue(forKey: token) }
        peer.channel.onFrame = { [weak self, weak peer] kind, data in
            guard let self, let peer else { return }
            do { try self.receive(kind, data, peer: peer) }
            catch { peer.channel.json(["kind": "error", "message": error.localizedDescription]) { peer.channel.close(error.localizedDescription) }; peer.clean() }
        }
        peer.channel.start()
    }
    private func receive(_ kind: UInt8, _ data: Data, peer: Peer) throws {
        if kind == 2 {
            guard peer.approved, let file = peer.file, Int64(data.count) <= peer.remaining else { throw PetLink.Failure.message("文件数据超出约定长度。") }
            try file.write(contentsOf: data)
            peer.remaining -= Int64(data.count); peer.hash.update(data: data)
            return
        }
        guard kind == 1, data.count <= 8192, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let message = object["kind"] as? String else { throw PetLink.Failure.message("无法识别传输消息。") }
        if message == "hello" {
            guard !peer.approved, !peer.awaitingApproval, object["version"] as? Int == 1,
                  let id = (object["device"] as? String).flatMap(UUID.init(uuidString:)),
                  let name = object["name"] as? String, !name.isEmpty, name.count <= 80 else { throw PetLink.Failure.message("设备握手无效。") }
            peer.name = name; peer.awaitingApproval = true
            let finish: (Bool) -> Void = { [weak self, weak peer] allowed in
                PetLink.queue.async {
                    guard let self, let peer else { return }
                    if allowed {
                        self.trusted.insert(id.uuidString)
                        UserDefaults.standard.set(Array(self.trusted), forKey: self.trustedKey)
                        peer.approved = true; peer.awaitingApproval = false
                        peer.channel.json(["kind": "ready"])
                        self.status("已连接 \(name)，文件会进入松萝收件箱。")
                    } else {
                        peer.channel.json(["kind": "error", "message": "Mac 未允许此设备配对。请在 Mac 确认后重试。"] ) { peer.channel.close("Mac 未允许此设备。") }
                        self.status("已拒绝设备连接。")
                    }
                }
            }
            if trusted.contains(id.uuidString) { finish(true) }
            else { DispatchQueue.main.async { [weak self] in if let authorize = self?.authorize { authorize(id, name, finish) } else { finish(false) } } }
            return
        }
        guard peer.approved else { throw PetLink.Failure.message("请先在 Mac 确认设备配对。") }
        if message == "offer" {
            guard peer.file == nil, let id = (object["id"] as? String).flatMap(UUID.init(uuidString:)),
                  let name = object["name"] as? String, let size = object["size"] as? Int64,
                  size >= 0, size <= PetLink.maxFileSize,
                  let hash = object["sha256"] as? String, hash.count == 64, hash.allSatisfy({ $0.isHexDigit }) else { throw PetLink.Failure.message("文件信息无效或超过 200MB。") }
            let safe = try PetLink.safeName(name)
            let temp = directory.appendingPathComponent(".partial-" + UUID().uuidString)
            guard FileManager.default.createFile(atPath: temp.path, contents: nil) else { throw PetLink.Failure.message("无法创建接收文件，请检查磁盘空间与文件夹权限。") }
            peer.temporary = temp
            peer.file = try FileHandle(forWritingTo: temp)
            peer.destination = directory.appendingPathComponent(String(id.uuidString.prefix(8)) + "-" + safe)
            peer.fileID = id.uuidString; peer.remaining = size; peer.expectedHash = hash.lowercased(); peer.hash = SHA256()
            peer.channel.json(["kind": "accept", "id": peer.fileID])
            status("正在接收 \(safe)…")
        } else if message == "end" {
            guard object["id"] as? String == peer.fileID, let file = peer.file, let temporary = peer.temporary, let destination = peer.destination, peer.remaining == 0 else { throw PetLink.Failure.message("文件未完整收到。") }
            guard PetLink.hex(peer.hash.finalize()) == peer.expectedHash else { throw PetLink.Failure.message("文件校验失败，请重新发送。") }
            try file.synchronize(); try file.close(); peer.file = nil
            try FileManager.default.moveItem(at: temporary, to: destination)
            peer.temporary = nil; peer.destination = nil
            peer.channel.json(["kind": "saved", "id": peer.fileID, "name": destination.lastPathComponent])
            status("已收到 \(destination.lastPathComponent)")
            DispatchQueue.main.async { [weak self] in self?.onReceived?(destination, peer.name) }
        } else { throw PetLink.Failure.message("传输状态无效。") }
    }
}
