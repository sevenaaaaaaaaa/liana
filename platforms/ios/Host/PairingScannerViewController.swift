import UIKit
import AVFoundation

final class PairingScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    private let capture = AVCaptureSession()
    private let cameraQueue = DispatchQueue(label: "dev.liana.pairing-camera")
    private var preview: AVCaptureVideoPreviewLayer!
    private let hint = UILabel()
    private let frameGuide = UIView()
    private var finished = false
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "扫描 Mac 桌宠配对码"
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancel))
        view.backgroundColor = .black
        let appearance = UINavigationBarAppearance(); appearance.configureWithTransparentBackground()
        appearance.titleTextAttributes = [.foregroundColor: UIColor.white]
        navigationController?.navigationBar.standardAppearance = appearance; navigationController?.navigationBar.scrollEdgeAppearance = appearance
        navigationController?.navigationBar.tintColor = .white
        preview = AVCaptureVideoPreviewLayer(session: capture); preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)
        frameGuide.layer.cornerRadius = 24; frameGuide.layer.borderWidth = 1.5; frameGuide.layer.borderColor = UIColor.white.withAlphaComponent(0.85).cgColor; frameGuide.isUserInteractionEnabled = false; view.addSubview(frameGuide)
        hint.font = LianaPalette.font(15); hint.backgroundColor = UIColor.black.withAlphaComponent(0.55); hint.layer.cornerRadius = 14; hint.clipsToBounds = true
        hint.text = "将 Mac 上的松萝二维码放进画面。"; hint.textColor = .white; hint.numberOfLines = 0; hint.textAlignment = .center
        hint.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(hint)
        NSLayoutConstraint.activate([hint.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24), hint.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24), hint.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -30)])
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews(); preview.frame = view.bounds
        let size = min(288, view.bounds.width - 72)
        frameGuide.frame = CGRect(x: (view.bounds.width-size)/2, y: view.bounds.midY-size/2-28, width: size, height: size)
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
            DispatchQueue.main.async {
                guard let self, self.view.window != nil else { return }
                if allowed { self.startCamera() } else { self.hint.text = "相机未授权，可返回使用「粘贴配对码」，或在系统设置允许相机。" }
            }
        }
    }
    private func startCamera() {
        cameraQueue.async { [weak self] in
            guard let self, !self.finished else { return }
            do {
                if self.capture.inputs.isEmpty {
                    guard let device = AVCaptureDevice.default(for: .video) else { throw PetLink.Failure.message("此设备没有可用相机，请返回粘贴配对码。") }
                    let input = try AVCaptureDeviceInput(device: device)
                    let output = AVCaptureMetadataOutput()
                    guard self.capture.canAddInput(input), self.capture.canAddOutput(output) else { throw PetLink.Failure.message("无法启动扫码相机。") }
                    self.capture.addInput(input); self.capture.addOutput(output)
                    output.setMetadataObjectsDelegate(self, queue: .main); output.metadataObjectTypes = [.qr]
                }
                self.capture.startRunning()
            } catch { DispatchQueue.main.async { [weak self] in self?.hint.text = error.localizedDescription } }
        }
    }
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !finished, let code = metadataObjects.compactMap({ ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }).first else { return }
        guard (try? PetLink.Profile.parse(code)) != nil else { hint.text = "请扫描 Mac 桌宠显示的松萝配对码。"; return }
        UISelectionFeedbackGenerator().selectionChanged()
        finished = true
        let callback = onCode
        dismiss(animated: true) { callback?(code) }
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        cameraQueue.async { [capture] in if capture.isRunning { capture.stopRunning() } }
    }
    @objc private func cancel() { finished = true; dismiss(animated: true) }
}
