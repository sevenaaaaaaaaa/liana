import Foundation
import Network

@main
struct PetLinkTests {
    static func main() throws {
        let profile = try PetLink.Profile.create(name: "QA Mac")
        let parsed = try PetLink.Profile.parse(profile.pairingCode)
        precondition(parsed.id == profile.id)
        for name in ["../test", "x/y", "x\\y", ".", "a\nb", "..\u{0}"] {
            do { _ = try PetLink.safeName(name); fatalError("Unsafe name accepted") } catch {}
        }
        do { _ = try PetLink.Profile.parse("liana-pet://pair/invalid"); fatalError("Invalid QR accepted") } catch {}
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("liana-petlink-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let input = directory.appendingPathComponent("文件.bin")
        var content = Data((0..<210_000).map { UInt8($0 % 251) })
        content.append(Data("跨包文件测试\n".utf8))
        try content.write(to: input)
        let output = directory.appendingPathComponent("received")
        let receiver = PetLinkReceiver(profile: profile, directory: output, trustNamespace: "PetLink.tests")
        var approvals = 0
        receiver.authorize = { _, _, finish in approvals += 1; finish(true) }
        let deviceID = UUID()
        let sender = PetLinkSender(deviceID: deviceID, deviceName: "QA iPhone")
        let wrong = try PetLink.Profile.create(name: "wrong key")
        let badSender = PetLinkSender(deviceID: UUID(), deviceName: "Unpaired")
        var partial: PetLinkChannel?
        var started = false
        var testedWrongKey = false
        var testedPartialCleanup = false
        var received: URL?
        receiver.onReceived = { url, _ in received = url }
        receiver.onStatus = { message in
            if let port = receiver.port, !started {
                started = true
                badSender.connect(profile: wrong, endpoint: .hostPort(host: "127.0.0.1", port: port))
            }
        }
        badSender.onReady = { fatalError("Wrong PSK was accepted") }
        badSender.onDisconnected = {
            guard !testedWrongKey, let port = receiver.port else { return }
            testedWrongKey = true
            print("Wrong pairing secret rejected")
            let channel = PetLinkChannel(NWConnection(to: .hostPort(host: "127.0.0.1", port: port), using: PetLink.parameters(key: profile.key)))
            partial = channel
            channel.onReady = { channel.json(["kind": "hello", "version": 1, "device": deviceID.uuidString, "name": "QA iPhone"]) }
            channel.onFrame = { kind, data in
                let object = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
                if object["kind"] as? String == "ready" {
                    channel.json(["kind": "offer", "id": UUID().uuidString, "name": "cancel.bin", "size": 1024, "sha256": String(repeating: "0", count: 64)])
                } else if object["kind"] as? String == "accept" {
                    channel.send(2, Data(repeating: 7, count: 100)) {
                        channel.close("Test cancellation")
                        channel.onReady = nil; channel.onFrame = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            let files = try! FileManager.default.contentsOfDirectory(atPath: output.path)
                            precondition(files.isEmpty, "Cancelled partial file was retained")
                            testedPartialCleanup = true
                            partial = nil
                            sender.connect(profile: profile, endpoint: .hostPort(host: "127.0.0.1", port: port))
                        }
                    }
                }
            }
            channel.start()
        }
        sender.onStatus = { print($0) }
        sender.onReady = { sender.send(input) }
        sender.onSaved = { _ in
            do {
                guard let received else { fatalError("Missing receive callback") }
                let receivedData = try Data(contentsOf: received)
                let files = try FileManager.default.contentsOfDirectory(atPath: output.path)
                precondition(receivedData == content)
                precondition(files.count == 1)
                precondition(testedWrongKey && testedPartialCleanup && approvals == 1)
                sender.disconnect(); receiver.stop()
                try? FileManager.default.removeItem(at: directory)
                UserDefaults.standard.removeObject(forKey: "PetLink.tests." + profile.id.uuidString)
                print("PetLink passed: QR validation, unsafe names, wrong-PSK rejection, cancelled-partial cleanup, remembered approval, real TLS transfer, chunking, SHA-256 and saved acknowledgement")
                exit(0)
            } catch { fatalError(error.localizedDescription) }
        }
        receiver.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { fatalError("TLS transfer timed out") }
        RunLoop.main.run()
    }
}
