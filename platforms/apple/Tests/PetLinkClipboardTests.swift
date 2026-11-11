import Foundation
import Network

@main
struct PetLinkClipboardTests {
    static func main() throws {
        let profile = try PetLink.Profile.create(name: "Clipboard QA")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let receiver = PetLinkReceiver(profile:profile,directory:folder,trustNamespace:"PetLink.clipboard.tests")
        receiver.authorize = { _,_,finish in finish(true) }
        let sender = PetLinkSender(deviceID:UUID(),deviceName:"Keyboard QA")
        var started = false
        var phase = 0
        var clipboard = "untouched"
        receiver.onStatus = { _ in
            guard !started,let port=receiver.port else { return }; started=true
            sender.connect(profile:profile,endpoint:.hostPort(host:"127.0.0.1",port:port))
        }
        sender.onReady = { sender.clipboard(text:"denied") }
        sender.onFailure = {
            if phase == 0 {
                precondition(clipboard == "untouched", "Disabled clipboard was modified")
                receiver.clipboardWrite = { clipboard=$0 }
                receiver.clipboardRead = { "Mac reply: \(clipboard)" }
                phase=1; sender.clipboard(text:"iPhone 🌿 \"quoted\"\nmultiline")
            } else if phase == 3 {
                sender.disconnect(); receiver.stop()
                try? FileManager.default.removeItem(at:folder)
                UserDefaults.standard.removeObject(forKey:"PetLink.clipboard.tests."+profile.id.uuidString)
                print("Clipboard passed: explicit opt-in, denied access, real TLS push/pull, UTF-8/JSON, acknowledgement and 4KB bound")
                exit(0)
            } else { fatalError("Unexpected clipboard failure") }
        }
        sender.onClipboard = { value in
            if phase == 1 {
                precondition(value == nil && clipboard.hasPrefix("iPhone"))
                phase=2; sender.clipboard()
            } else if phase == 2 {
                precondition(value == "Mac reply: \(clipboard)")
                phase=3; sender.clipboard(text:String(repeating:"x",count:4001))
            } else { fatalError("Unexpected clipboard response") }
        }
        receiver.start()
        DispatchQueue.main.asyncAfter(deadline:.now()+25) { fatalError("Clipboard test timed out") }
        RunLoop.main.run()
    }
}
