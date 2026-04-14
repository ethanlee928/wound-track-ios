import ARKit
import SwiftUI
import UIKit
import simd

/// SwiftUI wrapper around an `ARSession` configured with `.sceneDepth` frame
/// semantics. Live-previews the camera, shows a real-time distance HUD, and
/// fires `onCapture` with a synchronized RGB + depth + intrinsics bundle when
/// the user taps the shutter.
///
/// Capture gating:
/// - Refuses shutter if LiDAR is unsupported on this device (`sceneDepth`
///   frame semantic unavailable).
/// - Refuses shutter if the center-of-frame depth is < 0.20 m or invalid.
/// - Emits a live distance readout to `onDistanceUpdate` for HUD rendering.
struct ARCaptureView: UIViewControllerRepresentable {
    var onCapture: (ARCapturedFrame) -> Void
    var onDismiss: () -> Void

    func makeUIViewController(context: Context) -> ARCaptureViewController {
        let vc = ARCaptureViewController()
        vc.onCapture = onCapture
        vc.onDismiss = onDismiss
        return vc
    }

    func updateUIViewController(_ uiViewController: ARCaptureViewController, context: Context) {}
}

final class ARCaptureViewController: UIViewController, ARSessionDelegate {
    var onCapture: ((ARCapturedFrame) -> Void)?
    var onDismiss: (() -> Void)?

    private let session = ARSession()
    private let previewLayer = CALayer()
    private let hudLabel = UILabel()
    private let shutterButton = UIButton(type: .custom)
    private let closeButton = UIButton(type: .system)

    /// Captured shortest side clamps: below 20cm LiDAR is unreliable; above
    /// 60cm the wound is too small in frame to segment reliably.
    private static let minCaptureDistance: Float = 0.20
    private static let maxCaptureDistance: Float = 0.60

    private var latestCenterDistance: Float?
    private var isCapturing = false

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupPreview()
        setupHUD()
        setupShutter()
        setupCloseButton()
        session.delegate = self
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startSession()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        session.pause()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer.frame = view.bounds
    }

    // MARK: - Setup

    private func setupPreview() {
        previewLayer.contentsGravity = .resizeAspectFill
        view.layer.insertSublayer(previewLayer, at: 0)
    }

    private func setupHUD() {
        hudLabel.textColor = .white
        hudLabel.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        hudLabel.font = .monospacedSystemFont(ofSize: 15, weight: .semibold)
        hudLabel.textAlignment = .center
        hudLabel.layer.cornerRadius = 10
        hudLabel.clipsToBounds = true
        hudLabel.translatesAutoresizingMaskIntoConstraints = false
        hudLabel.text = "Initializing LiDAR…"
        view.addSubview(hudLabel)
        NSLayoutConstraint.activate([
            hudLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            hudLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            hudLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
            hudLabel.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    private func setupShutter() {
        shutterButton.translatesAutoresizingMaskIntoConstraints = false
        shutterButton.backgroundColor = .white
        shutterButton.layer.cornerRadius = 36
        shutterButton.layer.borderColor = UIColor.white.withAlphaComponent(0.8).cgColor
        shutterButton.layer.borderWidth = 4
        shutterButton.addTarget(self, action: #selector(shutterTapped), for: .touchUpInside)
        view.addSubview(shutterButton)
        NSLayoutConstraint.activate([
            shutterButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -32),
            shutterButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            shutterButton.widthAnchor.constraint(equalToConstant: 72),
            shutterButton.heightAnchor.constraint(equalToConstant: 72),
        ])
    }

    private func setupCloseButton() {
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setTitle("Cancel", for: .normal)
        closeButton.setTitleColor(.white, for: .normal)
        closeButton.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        closeButton.layer.cornerRadius = 8
        closeButton.contentEdgeInsets = UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        view.addSubview(closeButton)
        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            closeButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
        ])
    }

    // MARK: - Session

    private func startSession() {
        guard ARWorldTrackingConfiguration.supportsFrameSemantics([.sceneDepth, .smoothedSceneDepth]) else {
            hudLabel.text = "LiDAR not supported on this device"
            shutterButton.isEnabled = false
            shutterButton.alpha = 0.4
            return
        }
        let config = ARWorldTrackingConfiguration()
        // smoothedSceneDepth is temporally filtered and much less noisy. Fall
        // back to raw sceneDepth if the device doesn't offer the smoothed
        // variant.
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            config.frameSemantics.insert(.smoothedSceneDepth)
        } else {
            config.frameSemantics.insert(.sceneDepth)
        }
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        previewLayer.contents = ciImage(from: frame.capturedImage)
        updateHUD(with: frame)
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        hudLabel.text = "AR session failed: \(error.localizedDescription)"
    }

    // MARK: - HUD

    private func updateHUD(with frame: ARFrame) {
        guard let depth = frame.smoothedSceneDepth ?? frame.sceneDepth else {
            hudLabel.text = "Waiting for depth…"
            return
        }
        let d = centerDepth(from: depth.depthMap)
        latestCenterDistance = d
        guard let d = d else {
            hudLabel.text = "Depth: —"
            return
        }
        let cm = d * 100
        let gate: String
        let gateColor: UIColor
        if d < Self.minCaptureDistance {
            gate = "Move back"
            gateColor = .systemRed
        } else if d > Self.maxCaptureDistance {
            gate = "Move closer"
            gateColor = .systemOrange
        } else {
            gate = "Ready"
            gateColor = .systemGreen
        }
        hudLabel.text = String(format: "%.0f cm · %@", cm, gate)
        hudLabel.backgroundColor = gateColor.withAlphaComponent(0.55)
    }

    private func centerDepth(from depthMap: CVPixelBuffer) -> Float? {
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        let w = CVPixelBufferGetWidth(depthMap)
        let h = CVPixelBufferGetHeight(depthMap)
        let stride = CVPixelBufferGetBytesPerRow(depthMap) / MemoryLayout<Float>.size
        guard let base = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
        let ptr = base.assumingMemoryBound(to: Float.self)
        // 5x5 median-ish: average the valid values in a small box around the center.
        let cx = w / 2, cy = h / 2
        var sum: Float = 0
        var count = 0
        for dy in -2...2 {
            for dx in -2...2 {
                let x = cx + dx, y = cy + dy
                guard x >= 0, x < w, y >= 0, y < h else { continue }
                let v = ptr[y * stride + x]
                if v.isFinite, v > 0 {
                    sum += v; count += 1
                }
            }
        }
        return count == 0 ? nil : sum / Float(count)
    }

    // MARK: - Shutter

    @objc private func shutterTapped() {
        guard !isCapturing else { return }
        guard let d = latestCenterDistance else {
            flash(message: "No depth reading yet")
            return
        }
        guard d >= Self.minCaptureDistance, d <= Self.maxCaptureDistance else {
            flash(message: "Distance out of range (20–60 cm)")
            return
        }
        guard let frame = session.currentFrame else {
            flash(message: "No frame available")
            return
        }
        guard let depth = frame.smoothedSceneDepth ?? frame.sceneDepth else {
            flash(message: "No depth in frame")
            return
        }

        isCapturing = true
        shutterButton.isEnabled = false
        shutterButton.alpha = 0.4

        let pixelBuffer = frame.capturedImage
        guard let uiImage = uiImage(from: pixelBuffer) else {
            flash(message: "Image conversion failed")
            restoreShutter()
            return
        }
        let size = CGSize(
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        )
        let capture = ARCapturedFrame(
            image: uiImage,
            depthMap: depth.depthMap,
            confidenceMap: depth.confidenceMap,
            intrinsics: frame.camera.intrinsics,
            imageSize: size
        )
        onCapture?(capture)
    }

    @objc private func closeTapped() {
        onDismiss?()
    }

    private func restoreShutter() {
        isCapturing = false
        shutterButton.isEnabled = true
        shutterButton.alpha = 1
    }

    private func flash(message: String) {
        let original = hudLabel.text
        let originalColor = hudLabel.backgroundColor
        hudLabel.text = message
        hudLabel.backgroundColor = UIColor.systemRed.withAlphaComponent(0.7)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.hudLabel.text = original
            self?.hudLabel.backgroundColor = originalColor
        }
    }

    // MARK: - Image conversion

    private let ciContext = CIContext()

    /// Rotated CGImage used *only* for the on-screen preview. Rotation is
    /// fine here because the preview layer never feeds into inference.
    private func ciImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        let ci = CIImage(cvPixelBuffer: pixelBuffer).oriented(.right)
        return ciContext.createCGImage(ci, from: ci.extent)
    }

    /// Native (landscape-sensor-orientation) `UIImage` for inference. Intrinsics
    /// and depth map share this frame, so mask / depth / intrinsics all stay in
    /// lockstep. Downstream display code is responsible for re-orienting.
    private func uiImage(from pixelBuffer: CVPixelBuffer) -> UIImage? {
        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
