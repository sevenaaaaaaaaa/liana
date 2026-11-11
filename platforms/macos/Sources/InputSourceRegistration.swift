import Foundation

/// 一次安装对应一个容器及其声明的模式，统一持久化到第三方表。
/// 容器不能仅凭 TIS 的 selectable=false 被忽略：旧版曾将它同时写进两张表。
struct InputSourceRegistration {
    typealias Entry = [String: Any]
    let bundleID: String
    let modeIDs: [String]

    static let historicalBundleIDs: Set<String> = [
        "dev.inputflow.ime", "dev.inputflow.inputmethod", "dev.inputflow.inputmethod.dev",
        "dev.liana.ime", "dev.liana.inputmethod.ime",
    ]

    var managedBundleIDs: Set<String> { Self.historicalBundleIDs.union([bundleID]) }
    func owns(_ entry: Entry) -> Bool {
        guard let id = entry["Bundle ID"] as? String else { return false }
        return managedBundleIDs.contains(id)
    }

    var canonicalEntries: [Entry] {
        [["Bundle ID": bundleID, "InputSourceKind": "Keyboard Input Method"]]
            + modeIDs.map { ["Bundle ID": bundleID, "InputSourceKind": "Input Mode", "Input Mode": $0] }
    }

    /// 容器的默认 enabled 标志不是用户已添加的证据；必须有持久化模式。
    func hasModeRegistration(hitoolbox: [Entry], thirdParty: [Entry]) -> Bool {
        (hitoolbox + thirdParty).contains { entry in
            guard owns(entry) else { return false }
            if modeIDs.isEmpty { return entry["InputSourceKind"] as? String == "Keyboard Input Method" }
            guard entry["InputSourceKind"] as? String == "Input Mode",
                  let mode = entry["Input Mode"] as? String,
                  let parent = entry["Bundle ID"] as? String else { return false }
            return mode.hasPrefix(parent + ".")
        }
    }

    struct Result {
        let hitoolbox: [Entry]
        let thirdParty: [Entry]
        let changed: Bool
    }

    /// 纯函数：移除自己的旧注册，保留其他输入法及其顺序/附加字段，追加唯一声明。
    /// enabled=false 用于卸载；清理不会依赖某一瞬间的 TIS 缓存枚举。
    func normalize(hitoolbox: [Entry], thirdParty: [Entry], enabled: Bool) -> Result {
        let hb = hitoolbox.filter { !owns($0) }
        let tp = thirdParty.filter { !owns($0) } + (enabled ? canonicalEntries : [])
        return Result(hitoolbox: hb, thirdParty: tp,
            changed: !Self.equal(hitoolbox, hb) || !Self.equal(thirdParty, tp))
    }

    func isCanonical(hitoolbox: [Entry], thirdParty: [Entry]) -> Bool {
        !hitoolbox.contains(where: owns)
            && Self.equal(thirdParty.filter(owns), canonicalEntries)
    }

    static func equal(_ left: [Entry], _ right: [Entry]) -> Bool {
        NSArray(array: left).isEqual(to: right)
    }

    /// 只接受 Info.plist 声明且可见的模式，防止把历史或临时构建模式再次启用。
    static func declaredModes(in info: [String: Any], bundleID: String) -> [String] {
        guard let component = info["ComponentInputModeDict"] as? [String: Any],
              let modes = component["tsInputModeListKey"] as? [String: [String: Any]] else { return [] }
        let ordered = component["tsVisibleInputModeOrderedArrayKey"] as? [String] ?? modes.keys.sorted()
        var seen = Set<String>()
        return ordered.filter { id in
            guard id.hasPrefix(bundleID + "."), let mode = modes[id],
                  mode["TISInputSourceID"] as? String == id,
                  mode["tsInputModeIsVisibleKey"] as? Bool != false else { return false }
            return seen.insert(id).inserted
        }
    }
}
