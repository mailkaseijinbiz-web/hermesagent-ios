import SwiftUI
import AVFoundation

// MARK: - Connect View

struct ConnectView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showQRScanner = false
    @FocusState private var isURLFieldFocused: Bool

    var body: some View {
        ZStack {
            // Background gradient
            backgroundGradient
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 40) {
                    Spacer(minLength: 60)

                    // Logo & Title
                    logoSection

                    // Connection card
                    connectionCard

                    // QR Scanner button
                    qrButton

                    Spacer(minLength: 40)
                }
                .padding(.horizontal, 32)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .sheet(isPresented: $showQRScanner) {
            QRScannerView { scannedURL in
                appState.serverURL = scannedURL
                showQRScanner = false
                Task { await appState.connect() }
            }
        }
    }

    // MARK: - Background

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [
                Color(.systemBackground),
                Color(.systemBackground).opacity(0.95),
                Color.accentColor.opacity(0.03)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: - Logo Section

    private var logoSection: some View {
        VStack(spacing: 16) {
            // App icon
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 100, height: 100)

                Image(systemName: "bolt.horizontal.circle.fill")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(.primary)
            }

            VStack(spacing: 6) {
                Text("HermesAgent")
                    .font(.system(size: 34, weight: .light, design: .default))
                    .tracking(1.5)

                Text("AIアシスタント")
                    .font(.system(size: 15, weight: .light))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Connection Card

    private var connectionCard: some View {
        VStack(spacing: 20) {
            // URL Input
            VStack(alignment: .leading, spacing: 8) {
                Text("サーバーURL")
                    .font(.system(.caption, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)

                HStack(spacing: 12) {
                    Image(systemName: "network")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 16, weight: .light))

                    TextField("http://192.168.1.5:9119", text: $appState.serverURL)
                        .font(.system(.body, design: .monospaced, weight: .light))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .focused($isURLFieldFocused)
                        .submitLabel(.go)
                        .onSubmit {
                            Task { await appState.connect() }
                        }
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(.secondarySystemBackground))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color(.separator).opacity(0.5), lineWidth: 0.5)
                )
            }

            // Status indicator
            if let error = appState.connectionError {
                statusBanner(message: error, isError: true)
            }

            // Connect button
            Button {
                isURLFieldFocused = false
                Task { await appState.connect() }
            } label: {
                HStack(spacing: 10) {
                    if appState.isConnecting {
                        ProgressView()
                            .tint(Color(.systemBackground))
                            .scaleEffect(0.85)
                    } else {
                        Image(systemName: "link")
                            .font(.system(size: 15, weight: .medium))
                    }

                    Text(appState.isConnecting ? "接続中..." : "接続する")
                        .font(.system(.body, weight: .medium))
                }
                // Contrast with the Color.primary background in both light & dark mode
                // (was white-on-white in dark mode).
                .foregroundStyle(Color(.systemBackground))
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(appState.serverURL.isEmpty ? Color.secondary : Color.primary)
                )
            }
            .disabled(appState.isConnecting || appState.serverURL.isEmpty)
        }
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color(.separator).opacity(0.3), lineWidth: 0.5)
        )
    }

    // MARK: - QR Button

    private var qrButton: some View {
        Button {
            showQRScanner = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "qrcode.viewfinder")
                    .font(.system(size: 18, weight: .light))
                Text("QRコードで接続")
                    .font(.system(.body, weight: .light))
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(.secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color(.separator).opacity(0.3), lineWidth: 0.5)
            )
        }
    }

    // MARK: - Status Banner

    private func statusBanner(message: String, isError: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: isError ? "exclamationmark.triangle" : "checkmark.circle")
                .font(.system(size: 14, weight: .medium))
            Text(message)
                .font(.system(.caption, weight: .medium))
            Spacer()
        }
        .foregroundStyle(isError ? Color.red : Color.green)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill((isError ? Color.red : Color.green).opacity(0.08))
        )
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

// MARK: - QR Scanner View

struct QRScannerView: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    func makeUIViewController(context: Context) -> QRScannerViewController {
        let controller = QRScannerViewController()
        controller.onScan = onScan
        return controller
    }

    func updateUIViewController(_ uiViewController: QRScannerViewController, context: Context) {}
}

class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onScan: ((String) -> Void)?
    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var hasScanned = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupCamera()
        setupOverlay()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.layer.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if let session = captureSession, !session.isRunning {
            DispatchQueue.global(qos: .userInitiated).async {
                session.startRunning()
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if let session = captureSession, session.isRunning {
            DispatchQueue.global(qos: .userInitiated).async {
                session.stopRunning()
            }
        }
    }

    private func setupCamera() {
        let session = AVCaptureSession()
        captureSession = session

        guard let videoCaptureDevice = AVCaptureDevice.default(for: .video),
              let videoInput = try? AVCaptureDeviceInput(device: videoCaptureDevice),
              session.canAddInput(videoInput) else {
            showError()
            return
        }

        session.addInput(videoInput)

        let metadataOutput = AVCaptureMetadataOutput()
        guard session.canAddOutput(metadataOutput) else {
            showError()
            return
        }

        session.addOutput(metadataOutput)
        metadataOutput.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
        metadataOutput.metadataObjectTypes = [.qr]

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.frame = view.layer.bounds
        layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer)
        previewLayer = layer

        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
        }
    }

    private func setupOverlay() {
        // Close button
        let closeButton = UIButton(type: .system)
        closeButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        closeButton.tintColor = .white
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(closeButton)
        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            closeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            closeButton.widthAnchor.constraint(equalToConstant: 36),
            closeButton.heightAnchor.constraint(equalToConstant: 36)
        ])

        // Instruction label
        let label = UILabel()
        label.text = "QRコードをスキャン"
        label.textColor = .white
        label.font = .systemFont(ofSize: 17, weight: .light)
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -40),
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor)
        ])

        // Scanning frame
        let frameView = UIView()
        frameView.layer.borderColor = UIColor.white.withAlphaComponent(0.6).cgColor
        frameView.layer.borderWidth = 2
        frameView.layer.cornerRadius = 16
        frameView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(frameView)
        NSLayoutConstraint.activate([
            frameView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            frameView.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -30),
            frameView.widthAnchor.constraint(equalToConstant: 250),
            frameView.heightAnchor.constraint(equalToConstant: 250)
        ])
    }

    @objc private func closeTapped() {
        dismiss(animated: true)
    }

    private func showError() {
        let label = UILabel()
        label.text = "カメラを使用できません"
        label.textColor = .white
        label.font = .systemFont(ofSize: 17, weight: .light)
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !hasScanned,
              let metadataObject = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              metadataObject.type == .qr,
              let scannedValue = metadataObject.stringValue else {
            return
        }

        hasScanned = true
        AudioServicesPlaySystemSound(SystemSoundID(kSystemSoundID_Vibrate))

        captureSession?.stopRunning()
        dismiss(animated: true) { [weak self] in
            self?.onScan?(scannedValue)
        }
    }
}

#Preview {
    ConnectView()
        .environmentObject(AppState())
}
