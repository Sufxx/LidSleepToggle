import SwiftUI
import AVFoundation

// First-run pairing: scan the QR from the Mac's Settings → Phone tab, or type
// the topic + token by hand.

struct PairEmptyState: View {
    @Binding var showScanner: Bool
    @Binding var showManual: Bool

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            ZStack {
                Circle().fill(Lid.indigo.opacity(0.16)).frame(width: 110, height: 110).blur(radius: 18)
                Image(systemName: "laptopcomputer.and.iphone")
                    .font(.system(size: 52))
                    .foregroundStyle(Lid.indigo)
                    .shadow(color: Lid.indigo.opacity(0.7), radius: 16)
            }
            Text("Connect your Mac")
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text("Open LidSleepToggle on your Mac → Settings → Phone, turn on remote control, and scan the QR code here.")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center).padding(.horizontal, 30)
            VStack(spacing: 11) {
                Button { showScanner = true } label: {
                    Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .frame(maxWidth: .infinity).padding(.vertical, 15)
                        .background(Lid.sleepGradient, in: RoundedRectangle(cornerRadius: 16))
                        .foregroundStyle(.white)
                        .shadow(color: Lid.indigoDeep.opacity(0.45), radius: 14, y: 5)
                }
                Button { showManual = true } label: {
                    Text("Enter details manually")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .padding(.horizontal, 40)
            Spacer(); Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ManualPairView: View {
    var onPaired: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var topic = LidStore.topic
    @State private var token = LidStore.token

    var body: some View {
        NavigationStack {
            Form {
                Section("Pairing details") {
                    TextField("topic (lidsleep-…)", text: $topic)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("token", text: $token)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section {
                    Text("Both are shown on your Mac under Settings → Phone. The topic is the base name without the -cmd/-stats suffix.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Connect Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        LidStore.topic = topic.trimmingCharacters(in: .whitespaces)
                        LidStore.token = token.trimmingCharacters(in: .whitespaces)
                        onPaired(); dismiss()
                    }
                    .disabled(topic.isEmpty || token.isEmpty)
                }
            }
        }
    }
}

// MARK: - QR scanner

struct QRScannerView: UIViewControllerRepresentable {
    var onScan: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

    func makeUIViewController(context: Context) -> ScannerVC {
        let vc = ScannerVC()
        vc.onScan = { context.coordinator.handle($0) }
        return vc
    }
    func updateUIViewController(_ vc: ScannerVC, context: Context) {}

    final class Coordinator {
        let onScan: (String) -> Void
        private var fired = false
        init(onScan: @escaping (String) -> Void) { self.onScan = onScan }
        func handle(_ payload: String) {
            guard !fired else { return }
            fired = true
            onScan(payload)
        }
    }
}

final class ScannerVC: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onScan: ((String) -> Void)?
    private let session = AVCaptureSession()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.frame = view.layer.bounds
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.session.startRunning()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        session.stopRunning()
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput objects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard let obj = objects.first as? AVMetadataMachineReadableCodeObject,
              let payload = obj.stringValue else { return }
        session.stopRunning()
        onScan?(payload)
    }
}
