import AppKit
import CoreImage

// The real receiver window is compiled unchanged; unrelated pet rendering stays out of this test.
final class PetWindowController {
    static let shared = PetWindowController()
    static var isEnabled: Bool { false }
    func notify(_ value: String) {}
    func showToast(_ value: String, duration: Double) {}
}
final class GlassToast {
    static let shared = GlassToast()
    func show(_ value: String, symbol: String, duration: Double) {}
}

@main
struct PetLinkWindowTests {
    static func main() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let profile = try PetLink.Profile.create(name: "QA Mac")
        let code = profile.pairingCode
        let image = PetLinkWindow.pairingImage(code)!
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: CIContext(), options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])!
        let features = detector.features(in: CIImage(data: image.tiffRepresentation!)!) as! [CIQRCodeFeature]
        precondition(features.first?.messageString == code)
        let controller = PetLinkWindow.shared
        controller.window?.setFrameOrigin(NSPoint(x: -4000, y: -4000))
        controller.window?.orderFront(nil)
        defer { controller.window?.orderOut(nil) }
        let view = controller.window!.contentView!
        func views(_ node: NSView) -> [NSView] { [node] + node.subviews.flatMap(views) }
        (views(view).first { $0 is NSImageView } as? NSImageView)?.image = image
        view.layoutSubtreeIfNeeded()
        controller.window?.display()
        let titles = Set(views(view).compactMap { ($0 as? NSButton)?.title })
        precondition(titles.isSuperset(of: ["开始接收", "复制配对码", "撤销全部配对并换码", "打开松萝收件箱"]))
        for control in views(view) where control is NSButton || control is NSTextField {
            let rect = control.convert(control.bounds, to: view)
            precondition(rect.minY >= 0 && rect.maxY <= view.bounds.maxY, "Receiver control clipped")
        }
        if let path = CommandLine.arguments.dropFirst().first {
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let rendered = NSImage(size: view.bounds.size)
            rendered.lockFocus()
            NSColor.windowBackgroundColor.setFill()
            NSBezierPath(rect: view.bounds).fill()
            bitmap.draw(in: view.bounds)
            rendered.unlockFocus()
            let png = NSBitmapImageRep(data: rendered.tiffRepresentation!)!.representation(using: .png, properties: [:])!
            try png.write(to: URL(fileURLWithPath: path))
        }
        print("Mac receiver window: constructor, control bounds and QR round-trip passed")
    }
}
