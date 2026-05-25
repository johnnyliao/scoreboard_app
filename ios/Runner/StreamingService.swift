import Foundation
import HaishinKit
import AVFoundation
import UIKit
import CoreImage
import CoreText

class StreamingService: NSObject {
    private let rtmpConnection = RTMPConnection()
    private var rtmpStream: RTMPStream?
    private(set) var previewView: UIView?

    private let captureSession = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let captureQueue = DispatchQueue(label: "com.scoreboard.capture", qos: .userInitiated)
    private let ciContext = CIContext(options: [.workingColorSpace: NSNull()])

    // Cached per-frame objects (avoid 30 allocs/sec)
    private let compositeFilter = CIFilter(name: "CISourceOverCompositing")!
    private let celebFilter     = CIFilter(name: "CISourceOverCompositing")!
    private let deviceRGB       = CGColorSpaceCreateDeviceRGB()

    // Score overlay — main thread writes, capture queue reads
    private let overlayLock = NSLock()
    private var cachedOverlay: CIImage?
    private var overlaySize: CGSize = .zero

    // Celebration state — same lock
    private var celebrationStart: Date?
    private let celebrationDuration: TimeInterval = 3.0
    private var confettiParticles: [Particle] = []

    // RTMP connection state
    private var pendingStreamKey: String?
    private var streamStartCompletion: ((Bool, String?) -> Void)?
    private var connectTimeoutItem: DispatchWorkItem?

    // ── Particle ──────────────────────────────────────────────
    private struct Particle {
        let x0, y0: CGFloat        // UIKit coords (y=0 top)
        let vx, vy: CGFloat        // px/s, vy positive = downward
        let r, g, b: CGFloat
        let w, h: CGFloat
        let rot0, rotV: CGFloat    // radians, rad/s
    }

    override init() {
        super.init()
        setupCapture()
        setupStream()
    }

    // MARK: - Setup

    private func setupCapture() {
        captureSession.beginConfiguration()
        captureSession.sessionPreset = .hd1920x1080

        if let cam = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
           let input = try? AVCaptureDeviceInput(device: cam),
           captureSession.canAddInput(input) {
            captureSession.addInput(input)
        }

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: captureQueue)
        if captureSession.canAddOutput(videoOutput) {
            captureSession.addOutput(videoOutput)
            videoOutput.connection(with: .video)?.videoOrientation = .landscapeRight
        }
        captureSession.commitConfiguration()

        DispatchQueue.global(qos: .userInitiated).async {
            self.captureSession.startRunning()
        }
    }

    private func setupStream() {
        let stream = RTMPStream(connection: rtmpConnection)

        var videoSettings = VideoCodecSettings()
        videoSettings.videoSize = CGSize(width: 1920, height: 1080)
        videoSettings.bitRate = 4_500_000
        stream.videoSettings = videoSettings

        var audioSettings = AudioCodecSettings()
        audioSettings.bitRate = 128 * 1000
        stream.audioSettings = audioSettings

        stream.attachAudio(AVCaptureDevice.default(for: .audio)) { _, _ in }

        let preview = MTHKView(frame: .zero)
        preview.videoGravity = .resizeAspectFill
        preview.attachStream(stream)

        self.rtmpStream = stream
        self.previewView = preview
    }

    // MARK: - Score

    func updateScore(homeName: String, homeScore: Int, awayName: String, awayScore: Int) {
        let size = CGSize(width: 1920, height: 1080)
        let overlay = makeScoreOverlay(homeName: homeName, homeScore: homeScore,
                                       awayName: awayName, awayScore: awayScore, size: size)
        overlayLock.lock()
        cachedOverlay = overlay
        overlaySize = size
        overlayLock.unlock()
    }

    // MARK: - Stream control

    func startStream(url: String, key: String, completion: @escaping (Bool, String?) -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] videoOk in
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] audioOk in
                guard let self else { return }
                guard videoOk && audioOk else {
                    completion(false, "需要攝影機和麥克風權限"); return
                }
                DispatchQueue.main.async {
                    self.overlayLock.lock()
                    self.celebrationStart = nil
                    self.confettiParticles = []
                    self.overlayLock.unlock()

                    // Restart capture session if a previous stopStream shut it down
                    if !self.captureSession.isRunning {
                        DispatchQueue.global(qos: .userInitiated).async {
                            self.captureSession.startRunning()
                        }
                    }

                    // Store for use in rtmpStatusHandler
                    self.pendingStreamKey = key
                    self.streamStartCompletion = completion

                    // Wait for NetConnection.Connect.Success before publishing
                    self.rtmpConnection.addEventListener(
                        .rtmpStatus,
                        selector: #selector(self.rtmpStatusHandler(_:)),
                        observer: self
                    )

                    // 10-second timeout in case the event never fires
                    let timeout = DispatchWorkItem { [weak self] in
                        guard let self, self.streamStartCompletion != nil else { return }
                        self.rtmpConnection.removeEventListener(
                            .rtmpStatus,
                            selector: #selector(self.rtmpStatusHandler(_:)),
                            observer: self
                        )
                        self.streamStartCompletion?(false, "RTMP 連線逾時，請確認網路")
                        self.streamStartCompletion = nil
                        self.pendingStreamKey = nil
                    }
                    self.connectTimeoutItem = timeout
                    DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)

                    self.rtmpConnection.connect(url)
                }
            }
        }
    }

    @objc private func rtmpStatusHandler(_ notification: Notification) {
        guard let data = notification.userInfo?["data"] as? [String: Any],
              let code = data["code"] as? String else { return }

        if code == "NetConnection.Connect.Success" {
            connectTimeoutItem?.cancel()
            connectTimeoutItem = nil
            rtmpConnection.removeEventListener(
                .rtmpStatus,
                selector: #selector(rtmpStatusHandler(_:)),
                observer: self
            )
            rtmpStream?.publish(pendingStreamKey)
            DispatchQueue.main.async {
                self.streamStartCompletion?(true, nil)
                self.streamStartCompletion = nil
                self.pendingStreamKey = nil
            }
        } else if code.contains("Failed") || code.contains("Rejected") || code == "NetConnection.Connect.Closed" {
            connectTimeoutItem?.cancel()
            connectTimeoutItem = nil
            rtmpConnection.removeEventListener(
                .rtmpStatus,
                selector: #selector(rtmpStatusHandler(_:)),
                observer: self
            )
            DispatchQueue.main.async {
                self.streamStartCompletion?(false, "RTMP 連線失敗: \(code)")
                self.streamStartCompletion = nil
                self.pendingStreamKey = nil
            }
        }
    }

    func stopStream(completion: @escaping () -> Void) {
        connectTimeoutItem?.cancel()
        connectTimeoutItem = nil
        streamStartCompletion = nil
        pendingStreamKey = nil
        rtmpConnection.removeEventListener(
            .rtmpStatus,
            selector: #selector(rtmpStatusHandler(_:)),
            observer: self
        )
        rtmpStream?.close()
        rtmpConnection.close()
        overlayLock.lock()
        celebrationStart = nil
        confettiParticles = []
        overlayLock.unlock()
        DispatchQueue.global(qos: .userInitiated).async {
            self.captureSession.stopRunning()
        }
        completion()
    }

    // MARK: - Goal celebration

    func triggerGoal() {
        let colors: [(CGFloat, CGFloat, CGFloat)] = [
            (1.0, 0.22, 0.22), (0.25, 0.60, 1.0), (1.0, 0.88, 0.10),
            (0.20, 0.85, 0.35), (1.0, 0.50, 0.10), (0.88, 0.25, 0.90),
            (1.0, 1.0, 1.0),   (0.10, 0.90, 0.90), (1.0, 0.60, 0.80),
        ]
        let particles: [Particle] = (0..<100).map { _ in
            let c = colors[Int.random(in: 0..<colors.count)]
            return Particle(
                x0:   CGFloat.random(in: 0...1280),
                y0:   -CGFloat.random(in: 0...500),   // start above frame
                vx:   CGFloat.random(in: -120...120),
                vy:   CGFloat.random(in: 180...520),   // px/s downward
                r: c.0, g: c.1, b: c.2,
                w:    CGFloat.random(in: 9...20),
                h:    CGFloat.random(in: 14...26),
                rot0: CGFloat.random(in: 0...(2 * .pi)),
                rotV: CGFloat.random(in: -5...5)
            )
        }
        overlayLock.lock()
        celebrationStart = Date()
        confettiParticles = particles
        overlayLock.unlock()
    }

    // MARK: - Score overlay (main thread, UIKit)

    private func makeScoreOverlay(homeName: String, homeScore: Int,
                                   awayName: String, awayScore: Int,
                                   size: CGSize) -> CIImage? {
        let padding: CGFloat = 14
        let lineGap: CGFloat = 6
        let cornerRadius: CGFloat = 10
        let offsetX: CGFloat = 20
        let offsetY: CGFloat = 20

        let nameFont  = UIFont.systemFont(ofSize: 30, weight: .medium)
        let scoreFont = UIFont.monospacedDigitSystemFont(ofSize: 30, weight: .bold)

        let line1 = scoreLine(name: homeName, score: homeScore, nameFont: nameFont, scoreFont: scoreFont)
        let line2 = scoreLine(name: awayName, score: awayScore, nameFont: nameFont, scoreFont: scoreFont)
        let sz1 = line1.size(), sz2 = line2.size()

        let boxW = max(sz1.width, sz2.width) + padding * 2
        let boxH = sz1.height + lineGap + sz2.height + padding * 2
        let boxRect = CGRect(x: offsetX, y: offsetY, width: boxW, height: boxH)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let img = renderer.image { _ in
            UIColor(red: 0, green: 0, blue: 0, alpha: 0.72).setFill()
            UIBezierPath(roundedRect: boxRect, cornerRadius: cornerRadius).fill()
            line1.draw(at: CGPoint(x: offsetX + padding, y: offsetY + padding))
            line2.draw(at: CGPoint(x: offsetX + padding, y: offsetY + padding + sz1.height + lineGap))
        }
        return CIImage(image: img)
    }

    private func scoreLine(name: String, score: Int,
                            nameFont: UIFont, scoreFont: UIFont) -> NSAttributedString {
        let s = NSMutableAttributedString()
        s.append(NSAttributedString(string: "\(name)  ",
            attributes: [.font: nameFont, .foregroundColor: UIColor(white: 0.85, alpha: 1)]))
        s.append(NSAttributedString(string: "\(score)",
            attributes: [.font: scoreFont, .foregroundColor: UIColor.white]))
        return s
    }

    // MARK: - Celebration overlay (capture queue, CoreGraphics + CoreText)

    private func makeCelebrationOverlay(elapsed: CGFloat,
                                         particles: [Particle],
                                         frameW: Int, frameH: Int) -> CIImage? {
        guard let ctx = CGContext(
            data: nil, width: frameW, height: frameH,
            bitsPerComponent: 8, bytesPerRow: frameW * 4,
            space: deviceRGB,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue |
                        CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return nil }

        let W = CGFloat(frameW), H = CGFloat(frameH)
        let gravity: CGFloat = 420   // px/s²

        // ── White flash (0–1.5 s) ────────────────────────────
        if elapsed < 1.5 {
            let alpha = (1 - elapsed / 1.5) * 0.70
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: alpha))
            ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        }

        // ── Border glow pulse (0–2 s, 3 pulses) ──────────────
        if elapsed < 2.0 {
            let pulsePeriod: CGFloat = 2.0 / 3.0
            let t = elapsed.truncatingRemainder(dividingBy: pulsePeriod) / pulsePeriod
            let pulseAlpha = sin(t * .pi) * 0.85
            ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: pulseAlpha))
            ctx.setLineWidth(20)
            ctx.stroke(CGRect(x: 0, y: 0, width: W, height: H).insetBy(dx: 10, dy: 10))
        }

        // ── Confetti (0–2 s) ─────────────────────────────────
        if elapsed < 2.0 {
            for p in particles {
                let px    = p.x0 + p.vx * elapsed
                let pyTop = p.y0 + p.vy * elapsed + 0.5 * gravity * elapsed * elapsed
                let pyCG  = H - pyTop                      // flip y for CGContext
                guard pyCG > -40 && pyCG < H + 40 else { continue }

                ctx.saveGState()
                ctx.translateBy(x: px, y: pyCG)
                ctx.rotate(by: p.rot0 + p.rotV * elapsed)
                ctx.setFillColor(CGColor(red: p.r, green: p.g, blue: p.b, alpha: 0.92))
                ctx.fill(CGRect(x: -p.w / 2, y: -p.h / 2, width: p.w, height: p.h))
                ctx.restoreGState()
            }
        }

        // ── GOAL! text ────────────────────────────────────────
        // Scale animation: 0.6→3.0 (0–0.4 s ease-out), 3.0→1.3 (0.4–0.8 s), hold 1.3
        let scale: CGFloat
        if elapsed < 0.4 {
            let t = elapsed / 0.4
            scale = 0.6 + (1 - (1 - t) * (1 - t)) * 2.4   // ease-out quadratic, 0.6→3.0
        } else if elapsed < 0.8 {
            let t = (elapsed - 0.4) / 0.4
            scale = 3.0 - t * 1.7                           // linear, 3.0→1.3
        } else {
            scale = 1.3
        }
        let goalAlpha: CGFloat = elapsed > 2.5 ? max(0, 1 - (elapsed - 2.5) / 0.5) : 1.0
        guard goalAlpha > 0 else {
            return ctx.makeImage().map { CIImage(cgImage: $0) }
        }

        let fontSize: CGFloat = 140 * scale
        let font = CTFontCreateWithName("Impact" as CFString, fontSize, nil)

        // Outline pass (black stroke drawn slightly larger)
        for pass in 0...1 {
            let isOutline = pass == 0
            let color: CGColor = isOutline
                ? CGColor(red: 0, green: 0, blue: 0, alpha: goalAlpha)
                : CGColor(red: 1, green: 0.92, blue: 0.10, alpha: goalAlpha)

            let attrs: [CFString: Any] = [
                kCTFontAttributeName: font,
                kCTForegroundColorAttributeName: color,
            ]
            let attrStr = CFAttributedStringCreate(nil, "GOAL!" as CFString,
                                                    attrs as CFDictionary)!
            let line = CTLineCreateWithAttributedString(attrStr)
            let bounds = CTLineGetBoundsWithOptions(line, [])

            let textX = (W - bounds.width) / 2 - bounds.origin.x
            let textY = H / 2 - bounds.height / 2 - bounds.origin.y

            if isOutline {
                for dx: CGFloat in [-3, 3] {
                    for dy: CGFloat in [-3, 3] {
                        ctx.textMatrix = .identity
                        ctx.textPosition = CGPoint(x: textX + dx, y: textY + dy)
                        CTLineDraw(line, ctx)
                    }
                }
            } else {
                ctx.textMatrix = .identity
                ctx.textPosition = CGPoint(x: textX, y: textY)
                CTLineDraw(line, ctx)
            }
        }

        // ── Spotlight sweep (0.2–1.0 s) ──────────────────────
        // Diagonal white beam sweeping left→right over GOAL! text
        if elapsed >= 0.2 && elapsed < 1.0 {
            let t = (elapsed - 0.2) / 0.8                   // 0→1
            let beamX = -250 + t * (W + 500)
            let beamAlpha = sin(t * .pi) * 0.45             // fade in then out
            ctx.saveGState()
            ctx.translateBy(x: beamX, y: H / 2)
            ctx.rotate(by: 0.32)                            // ~18° tilt
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: beamAlpha))
            ctx.fill(CGRect(x: -90, y: -H, width: 180, height: H * 2))
            ctx.restoreGState()
        }

        return ctx.makeImage().map { CIImage(cgImage: $0) }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension StreamingService: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = sampleBuffer.imageBuffer else {
            rtmpStream?.append(sampleBuffer)
            return
        }

        // Read all shared state in one lock
        overlayLock.lock()
        let scoreOverlay  = cachedOverlay
        let celStart      = celebrationStart
        let celParticles  = confettiParticles
        overlayLock.unlock()

        let frameW = CVPixelBufferGetWidth(pixelBuffer)
        let frameH = CVPixelBufferGetHeight(pixelBuffer)
        let frameBounds = CGRect(x: 0, y: 0, width: frameW, height: frameH)

        // Build a lazy CIImage chain — one final render covers all layers
        var current = CIImage(cvPixelBuffer: pixelBuffer)

        // Layer 1: score overlay
        if let overlay = scoreOverlay {
            compositeFilter.setValue(overlay.cropped(to: frameBounds), forKey: kCIInputImageKey)
            compositeFilter.setValue(current, forKey: kCIInputBackgroundImageKey)
            if let out = compositeFilter.outputImage { current = out }
        }

        // Layer 2: celebration (white flash + confetti + GOAL! text)
        if let start = celStart {
            let elapsed = CGFloat(-start.timeIntervalSinceNow)
            if elapsed >= CGFloat(celebrationDuration) {
                overlayLock.lock()
                if celebrationStart == start { celebrationStart = nil; confettiParticles = [] }
                overlayLock.unlock()
            } else if let celOverlay = makeCelebrationOverlay(
                elapsed: elapsed, particles: celParticles, frameW: frameW, frameH: frameH) {
                celebFilter.setValue(celOverlay, forKey: kCIInputImageKey)
                celebFilter.setValue(current,    forKey: kCIInputBackgroundImageKey)
                if let out = celebFilter.outputImage { current = out }
            }
        }

        // One GPU render for all layers
        ciContext.render(current, to: pixelBuffer, bounds: frameBounds, colorSpace: deviceRGB)
        rtmpStream?.append(sampleBuffer)
    }
}
