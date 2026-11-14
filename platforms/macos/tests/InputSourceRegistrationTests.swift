import Foundation

@main
struct InputSourceRegistrationTests {
    static func main() {
        let id = "dev.liana.inputmethod.ime"
        let policy = InputSourceRegistration(bundleID: id, modeIDs: [id + ".zh"])
        let parent: [String: Any] = ["Bundle ID": id, "InputSourceKind": "Keyboard Input Method"]
        let mode: [String: Any] = ["Bundle ID": id, "InputSourceKind": "Input Mode", "Input Mode": id + ".zh"]
        let unrelated: [String: Any] = ["Bundle ID": "org.other.ime", "InputSourceKind": "Input Mode", "Input Mode": "x", "custom": ["keep", 7]]
        let similar: [String: Any] = ["Bundle ID": id + ".other-product", "InputSourceKind": "Keyboard Input Method"]
        // 上次漏检的真实状态：TIS 可选模式只有一个，但容器仍跨表重复。
        precondition(!policy.isCanonical(hitoolbox: [parent], thirdParty: [parent, mode]))
        let old: [String: Any] = ["Bundle ID": "dev.inputflow.inputmethod.dev", "InputSourceKind": "Keyboard Input Method"]
        let result = policy.normalize(hitoolbox: [unrelated, parent, mode, old, similar],
            thirdParty: [parent, mode, parent, old, unrelated, unrelated], enabled: true)
        precondition(InputSourceRegistration.equal(result.hitoolbox, [unrelated, similar]))
        precondition(InputSourceRegistration.equal(result.thirdParty, [unrelated, unrelated, parent, mode]))
        precondition(policy.isCanonical(hitoolbox: result.hitoolbox, thirdParty: result.thirdParty))
        precondition(result.changed)
        let repeated = policy.normalize(hitoolbox: result.hitoolbox, thirdParty: result.thirdParty, enabled: true)
        precondition(!repeated.changed)
        let removed = policy.normalize(hitoolbox: result.hitoolbox, thirdParty: result.thirdParty, enabled: false)
        precondition(InputSourceRegistration.equal(removed.thirdParty, [unrelated, unrelated]))
        let fresh = policy.normalize(hitoolbox: [], thirdParty: [], enabled: true)
        precondition(InputSourceRegistration.equal(fresh.thirdParty, [parent, mode]))
        precondition(!policy.isCanonical(hitoolbox: [], thirdParty: [parent]))
        precondition(!policy.hasModeRegistration(hitoolbox: [parent], thirdParty: []))
        precondition(!policy.hasModeRegistration(hitoolbox: [], thirdParty: []))
        precondition(policy.hasModeRegistration(hitoolbox: [], thirdParty: [parent, mode]))
        // 系统持久化时会重排数组（实测模式行在容器行之前）：内容相同即视为规范，不按顺序判失败。
        precondition(policy.isCanonical(hitoolbox: [], thirdParty: [mode, parent]))
        precondition(InputSourceRegistration.equalIgnoringOrder([parent, mode], [mode, parent]))
        precondition(InputSourceRegistration.equalIgnoringOrder([unrelated, parent, mode], [mode, parent, unrelated]))
        precondition(!InputSourceRegistration.equalIgnoringOrder([parent, mode], [mode]))
        precondition(!InputSourceRegistration.equalIgnoringOrder([parent, mode], [parent, parent]))
        precondition(!InputSourceRegistration.equalIgnoringOrder(
            [["Bundle ID": id, "InputSourceKind": "Keyboard Input Method", "custom": ["keep", 7]]], [parent]))
        let info: [String: Any] = ["ComponentInputModeDict": [
            "tsVisibleInputModeOrderedArrayKey": [id + ".zh", id + ".zh", "old.mode", id + ".hidden"],
            "tsInputModeListKey": [id + ".zh": ["TISInputSourceID": id + ".zh"],
                id + ".hidden": ["TISInputSourceID": id + ".hidden", "tsInputModeIsVisibleKey": false]]]]
        precondition(InputSourceRegistration.declaredModes(in: info, bundleID: id) == [id + ".zh"])
        print("Input source registration: container duplication, migration, unrelated records, fresh install, uninstall, declared modes and idempotency passed")
    }
}
