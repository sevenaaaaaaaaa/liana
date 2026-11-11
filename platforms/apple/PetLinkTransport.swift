import Foundation
import Network
import Security
import CryptoKit

enum PetLink {
    static let serviceType = "_liana-pet._tcp"
    static let maxFileSize: Int64 = 200 * 1024 * 1024
    static let maxFrame = 70 * 1024
    static let queue = DispatchQueue(label: "dev.liana.petlink", qos: .userInitiated)

    struct Profile: Codable {
        var version = 1
        let id: UUID
        let name: String
        let key: Data
        var service: String { "Liana-" + id.uuidString }
        var pairingCode: String { "liana-pet://pair/" + (try! JSONEncoder().encode(self)).base64EncodedString() }
        static func parse(_ code: String) throws -> Profile {
            let prefix = "liana-pet://pair/"
            guard code.count < 4096, code.hasPrefix(prefix),
                  let data = Data(base64Encoded: String(code.dropFirst(prefix.count))),
                  let profile = try? JSONDecoder().decode(Self.self, from: data),
                  profile.version == 1, profile.key.count == 32, !profile.name.isEmpty, profile.name.count <= 80 else { throw Failure.message("配对码无效，请重新扫描 Mac 上的二维码。") }
            return profile
        }
        static func create(name: String) throws -> Profile {
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw Failure.message("无法生成配对密钥。") }
            return Profile(id: UUID(), name: String(name.prefix(80)), key: Data(bytes))
        }
    }

    enum Failure: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
    }

    static func parameters(key: Data) -> NWParameters {
        precondition(key.count == 32)
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        let psk = key.withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data("liana-pet-v1".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, psk as __DispatchData, identity as __DispatchData)
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.includePeerToPeer = false
        parameters.prohibitedInterfaceTypes = [.cellular]
        return parameters
    }

    static func store(_ profile: Profile, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "dev.liana.petlink", kSecAttrAccount as String: account]
        let data = try JSONEncoder().encode(profile)
        let result = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if result == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw Failure.message("无法保存配对，请检查钥匙串权限。") }
        } else if result != errSecSuccess { throw Failure.message("无法更新配对密钥。") }
    }

    static func load(account: String) -> Profile? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "dev.liana.petlink", kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data,
              let profile = try? JSONDecoder().decode(Profile.self, from: data), profile.key.count == 32 else { return nil }
        return profile
    }

    static func forget(account: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "dev.liana.petlink", kSecAttrAccount as String: account] as CFDictionary)
    }

    static func safeName(_ name: String) throws -> String {
        guard !name.isEmpty, name != ".", name != "..", name.count <= 180,
              !name.contains("/"), !name.contains("\\"), !name.contains(":"),
              name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { throw Failure.message("文件名无效。") }
        return name
    }

    static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let block = try handle.read(upToCount: 65_536), !block.isEmpty { hash.update(data: block) }
        return hex(hash.finalize())
    }
    static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 { bytes.map { String(format: "%02x", $0) }.joined() }
}

/// TLS-PSK authenticates the QR secret; each bounded frame is either JSON or a file chunk.
final class PetLinkChannel {
    let connection: NWConnection
    var onReady: (() -> Void)?
    var onFrame: ((UInt8, Data) -> Void)?
    var onClose: ((String) -> Void)?
    private var closed = false
    private var timeout: DispatchWorkItem?

    init(_ connection: NWConnection) { self.connection = connection }
    func start() {
        armTimeout(20)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.armTimeout(300); self.onReady?(); self.header()
            case .failed(let error): self.close("连接失败：\(error.localizedDescription)")
            case .cancelled: self.close("连接已关闭。")
            case .waiting(let error): self.close("无法连接：\(error.localizedDescription)")
            default: break
            }
        }
        connection.start(queue: PetLink.queue)
    }
    func armTimeout(_ seconds: Double) {
        timeout?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.close("连接超时，请保持两端开启后重试。") }
        timeout = work
        PetLink.queue.asyncAfter(deadline: .now() + seconds, execute: work)
    }
    func close(_ reason: String) {
        guard !closed else { return }
        closed = true; timeout?.cancel()
        connection.cancel()
        onClose?(reason)
    }
    func json(_ object: [String: Any], completion: (() -> Void)? = nil) {
        guard let data = try? JSONSerialization.data(withJSONObject: object), data.count <= 8192 else { close("消息过大。"); return }
        send(1, data, completion: completion)
    }
    func send(_ kind: UInt8, _ data: Data, completion: (() -> Void)? = nil) {
        guard !closed, data.count + 1 <= PetLink.maxFrame else { return }
        var size = UInt32(data.count + 1).bigEndian
        var packet = Data(bytes: &size, count: 4)
        packet.append(kind); packet.append(data)
        connection.send(content: packet, completion: .contentProcessed { [weak self] error in
            guard let self, !self.closed else { return }
            if let error { self.close(error.localizedDescription) } else { self.armTimeout(300); completion?() }
        })
    }
    private func header() {
        read(4) { [weak self] bytes in
            guard let self else { return }
            let count = bytes.reduce(0) { ($0 << 8) | Int($1) }
            guard count > 1, count <= PetLink.maxFrame else { self.close("文件消息长度无效。"); return }
            self.read(count) { [weak self] frame in
                guard let self, let kind = frame.first else { return }
                self.armTimeout(300)
                self.onFrame?(kind, Data(frame.dropFirst()))
                if !self.closed { self.header() }
            }
        }
    }
    private func read(_ count: Int, collected: Data = Data(), done: @escaping (Data) -> Void) {
        guard !closed else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: count - collected.count) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            var value = collected
            if let data { value.append(data) }
            if let error { self.close(error.localizedDescription) }
            else if value.count == count { done(value) }
            else if complete { self.close("连接中断，文件尚未确认送达。") }
            else { self.read(count, collected: value, done: done) }
        }
    }
}
