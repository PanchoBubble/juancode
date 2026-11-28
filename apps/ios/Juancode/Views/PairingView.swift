@preconcurrency import AVFoundation
import SwiftUI

/// First run: scan the QR from the Mac's Settings → Phone, or paste its link
/// (the simulator has no camera).
struct PairingView: View {
    let onPaired: (Pairing) -> Void
    @State private var pasted = ""
    @State private var failed = false

    var body: some View {
        VStack(spacing: 16) {
            Text("Pair with your Mac").font(.title2.bold())
            Text("juancode → Settings → Phone").foregroundStyle(.secondary)
            QRScanner { accept($0) }
                .frame(maxWidth: .infinity, maxHeight: 360)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel("Camera viewfinder for the pairing QR")
            TextField("or paste juancode://pair?…", text: $pasted)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit { accept(pasted) }
            if failed { Text("That is not a juancode pairing link.").foregroundStyle(.red) }
        }
        .padding()
    }

    private func accept(_ text: String) {
        if let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
           let pairing = Pairing(url: url) {
            onPaired(pairing)
        } else {
            failed = true
        }
    }
}

/// AVFoundation QR reader. Calls back with each decoded string.
private struct QRScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> Controller { Controller(onCode: onCode) }
    func updateUIViewController(_ vc: Controller, context: Context) {}

    final class Controller: UIViewController, @preconcurrency AVCaptureMetadataOutputObjectsDelegate {
        let onCode: (String) -> Void
        private let session = AVCaptureSession()
        private var preview: AVCaptureVideoPreviewLayer?

        init(onCode: @escaping (String) -> Void) {
            self.onCode = onCode
            super.init(nibName: nil, bundle: nil)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .secondarySystemBackground
            guard let camera = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: camera),
                  session.canAddInput(input) else { return }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            view.layer.addSublayer(layer)
            preview = layer
            let session = self.session
            DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            preview?.frame = view.bounds
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            session.stopRunning()
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            guard let code = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
            onCode(code)
        }
    }
}
