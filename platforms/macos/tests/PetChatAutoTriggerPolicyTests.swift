import Foundation
import CoreGraphics

// 回归：自动进入桌宠聊天的触发判定（纯逻辑，不依赖真实 NSEvent / 辅助功能权限）。
//
// 编译运行方式（沿用 tests/ 里其它回归的 swiftc 手工编译）：
//   swiftc -D PETCHAT_AUTO_TRIGGER_POLICY_TEST \
//     platforms/macos/Sources/PetChat.swift \
//     platforms/macos/tests/PetChatAutoTriggerPolicyTests.swift \
//     -o /tmp/liana-pet-chat-trigger-tests
//   /tmp/liana-pet-chat-trigger-tests

@main
struct PetChatAutoTriggerPolicyTests {
    static func main() {
        let pet = CGRect(x: 900, y: 100, width: 160, height: 200)
        let onPet = CGPoint(x: 980, y: 200)
        let outsidePet = CGPoint(x: 200, y: 600)
        var focusQueries = 0

        func focusQuery(_ value: Bool) -> () -> Bool {
            { focusQueries += 1; return value }
        }

        func input(mouse: CGPoint,
                   frontmost: PetChatAutoTriggerPolicy.Frontmost,
                   focus: Bool,
                   letters: Int = PetChatAutoTriggerPolicy.minimumLetters,
                   snoozed: Bool = false,
                   open: Bool = false,
                   frame: CGRect? = pet) -> PetChatAutoTriggerPolicy.Input {
            PetChatAutoTriggerPolicy.Input(
                frontmost: frontmost,
                mouseLocation: mouse,
                petFrame: frame,
                letterCount: letters,
                isSnoozed: snoozed,
                isChatOpen: open,
                focusIsTextInput: focusQuery(focus))
        }

        // 用户明确要求：鼠标在别的 App 上时绝不抢夺输入焦点。
        precondition(!PetChatAutoTriggerPolicy.shouldOpen(
            input(mouse: outsidePet, frontmost: .finder, focus: false)))

        // 鼠标在桌宠上、前台是桌面、焦点不是输入框 → 继续支持「在桌面上直接打字叫出聊天」。
        precondition(PetChatAutoTriggerPolicy.shouldOpen(
            input(mouse: onPet, frontmost: .finder, focus: false)))

        // 焦点在输入框 → 用户正在输入，不打扰（鼠标停在桌宠上也不弹）。
        precondition(!PetChatAutoTriggerPolicy.shouldOpen(
            input(mouse: onPet, frontmost: .finder, focus: true)))

        // 松萝自己是前台 → 不弹，避免自己弹自己。
        precondition(!PetChatAutoTriggerPolicy.shouldOpen(
            input(mouse: onPet, frontmost: .liana, focus: false)))

        // 第三方 App（含游戏）前台 → 不打断。
        precondition(!PetChatAutoTriggerPolicy.shouldOpen(
            input(mouse: onPet, frontmost: .thirdParty, focus: false)))

        // 字母不够 4 个 / 自动触发 snooze 中 / 聊天已打开 / 桌宠隐藏 → 都不弹。
        precondition(!PetChatAutoTriggerPolicy.shouldOpen(
            input(mouse: onPet, frontmost: .finder, focus: false, letters: 3)))
        precondition(!PetChatAutoTriggerPolicy.shouldOpen(
            input(mouse: onPet, frontmost: .finder, focus: false, snoozed: true)))
        precondition(!PetChatAutoTriggerPolicy.shouldOpen(
            input(mouse: onPet, frontmost: .finder, focus: false, open: true)))
        precondition(!PetChatAutoTriggerPolicy.shouldOpen(
            input(mouse: onPet, frontmost: .finder, focus: false, frame: nil)))

        // 辅助功能查询是最后一步：鼠标不在桌宠上时不查 AX，避免每次打字都打扰系统。
        focusQueries = 0
        _ = PetChatAutoTriggerPolicy.shouldOpen(
            input(mouse: outsidePet, frontmost: .finder, focus: true))
        precondition(focusQueries == 0, "AX focus query must be lazy when the mouse is elsewhere")
        focusQueries = 0
        _ = PetChatAutoTriggerPolicy.shouldOpen(
            input(mouse: onPet, frontmost: .finder, focus: true))
        precondition(focusQueries == 1, "AX focus query should run once when the mouse is on the pet")

        // 窗口边界本身也算在桌宠上。
        precondition(PetChatAutoTriggerPolicy.shouldOpen(
            input(mouse: CGPoint(x: pet.minX, y: pet.minY), frontmost: .finder, focus: false)))

        print("Pet chat auto trigger: mouse elsewhere, mouse on pet, text focus, Liana frontmost, third-party, threshold, snooze, open, hidden pet, lazy AX query and frame boundary passed")
    }
}
