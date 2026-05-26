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

    // ── Camera pipeline (we own this, not HaishinKit) ─────────
    private let captureSession  = AVCaptureSession()
    private let videoOutput     = AVCaptureVideoDataOutput()
    private let captureQueue    = DispatchQueue(label: "com.scoreboard.capture", qos: .userInitiated)
    private let sessionQueue    = DispatchQueue(label: "com.scoreboard.session",  qos: .userInitiated)
    private let ciContext        = CIContext(options: [.workingColorSpace: NSNull()])
    private var captureConfigured = false

    // Cached per-frame CIFilter objects
    private let compositeFilter = CIFilter(name: "CISourceOverCompositing")!
    private let celebFilter     = CIFilter(name: "CISourceOverCompositing")!
    private let deviceRGB       = CGColorSpaceCreateDeviceRGB()

    // Score overlay — main thread writes, capture queue reads
    private let overlayLock = NSLock()
    private var cachedOverlay: CIImage?

    // Celebration state — same lock
    private var celebrationStart: Date?
    private let celebrationDuration: TimeInterval = 3.0
    private var confettiParticles: [Particle] = []

    // RTMP connection state — main thread only
    private var pendingStreamKey: String?
    private var streamStartCompletion: ((Bool, String?) -> Void)?
    private var connectTimeoutItem: DispatchWorkItem?

    // Double-tap / stale-closure guard — main thread only
    private var isStarting  = false
    private var isStreaming = false
    private var startToken  = UUID()

    // Audio attachment — deferred until permission is confirmed
    private var audioAttached = false

    // ── Particle ──────────────────────────────────────────────
    private struct Particle {
        let x0, y0: CGFloat
        let vx, vy: CGFloat
        let r, g, b: CGFloat
        let w, h: CGFloat
        let rot0, rotV: CGFloat
    }

    override init() {
        super.init()
        setupStream()
        // Camera is set up lazily in startStream() after permissions are confirmed.
    }

    // MARK: - Setup

    // Must be called from sessionQueue.
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
        captureConfigured = true
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
        overlayLock.unlock()
    }

    // MARK: - Stream control

    // Called on main thread from AppDelegate / platform channel.
    func startStream(url: String, key: String, completion: @escaping (Bool, String?) -> Void) {
        guard !isStarting && !isStreaming else {
            completion(false, "直播已在啟動中")
            return
        }
        let token = UUID()
        startToken = token
        isStarting = true
        streamStartCompletion = completion  // set early so failStart can reach it from any path

        overlayLock.lock()
        celebrationStart = nil
        confettiParticles = []
        overlayLock.unlock()

        AVCaptureDevice.requestAccess(for: .video) { [weak self] videoOk in
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] audioOk in
                guard let self else { return }
                guard videoOk && audioOk else {
                    DispatchQueue.main.async { self.failStart("需要攝影機和麥克風權限") }
                    return
                }

                // All AVCaptureSession work runs on sessionQueue.
                self.sessionQueue.async {
                    if !self.captureConfigured {
                        self.setupCapture()
                    } else if self.captureSession.inputs.isEmpty {
                        // First launch: permission granted after setupCapture ran — add input now.
                        self.captureSession.beginConfiguration()
                        if let cam = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                           let input = try? AVCaptureDeviceInput(device: cam),
                           self.captureSession.canAddInput(input) {
                            self.captureSession.addInput(input)
                        }
                        self.captureSession.commitConfiguration()
                        self.videoOutput.connection(with: .video)?.videoOrientation = .landscapeRight
                    }

                    if !self.captureSession.isRunning {
                        self.captureSession.startRunning()
                    }

                    DispatchQueue.main.async {
                        guard self.isStarting && self.startToken == token else { return }

                        self.attachAudioIfNeeded()
                        self.pendingStreamKey = key

                        self.rtmpConnection.addEventListener(
                            .rtmpStatus,
                            selector: #selector(self.rtmpConnectHandler(_:)),
                            observer: self
                        )

                        let timeout = DispatchWorkItem { [weak self] in
                            guard let self, self.streamStartCompletion != nil else { return }
                            self.failStart("RTMP 連線逾時，請確認網路")
                        }
                        self.connectTimeoutItem = timeout
                        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: timeout)

                        self.rtmpConnection.connect(url)
                    }
                }
            }
        }
    }

    // Called on main thread after audio permission confirmed.
    private func attachAudioIfNeeded() {
        guard !audioAttached else { return }
        rtmpStream?.attachAudio(AVCaptureDevice.default(for: .audio)) { _, _ in }
        audioAttached = true
    }

    // Must be called on main thread. Tears down everything and reports failure to Flutter.
    private func failStart(_ message: String) {
        connectTimeoutItem?.cancel()
        connectTimeoutItem = nil

        rtmpConnection.removeEventListener(
            .rtmpStatus,
            selector: #selector(rtmpConnectHandler(_:)),
            observer: self
        )
        rtmpStream?.removeEventListener(
            .rtmpStatus,
            selector: #selector(rtmpPublishHandler(_:)),
            observer: self
        )

        rtmpStream?.close()
        rtmpConnection.close()

        let completion = streamStartCompletion
        isStarting = false
        isStreaming = false
        streamStartCompletion = nil
        pendingStreamKey = nil

        sessionQueue.async {
            if self.captureSession.isRunning {
                self.captureSession.stopRunning()
            }
            DispatchQueue.main.async {
                completion?(false, message)
            }
        }
    }

    // Step 1: HaishinKit may call this off main thread — bounce immediately.
    @objc private func rtmpConnectHandler(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in self?.handleRtmpConnect(notification) }
    }

    private func handleRtmpConnect(_ notification: Notification) {
        let event = Event.from(notification)
        guard let data = event.data as? [String: Any?],
              let code = data["code"] as? String else { return }

        if code == "NetConnection.Connect.Success" {
            rtmpConnection.removeEventListener(
                .rtmpStatus,
                selector: #selector(rtmpConnectHandler(_:)),
                observer: self
            )
            rtmpStream?.addEventListener(
                .rtmpStatus,
                selector: #selector(rtmpPublishHandler(_:)),
                observer: self
            )
            guard let key = pendingStreamKey else {
                failStart("找不到串流金鑰")
                return
            }
            rtmpStream?.publish(key)
        } else if code.contains("Failed") || code.contains("Rejected") || code == "NetConnection.Connect.Closed" {
            failStart("RTMP 連線失敗: \(code)")
        }
    }

    // Step 2: HaishinKit may call this off main thread — bounce immediately.
    @objc private func rtmpPublishHandler(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in self?.handleRtmpPublish(notification) }
    }

    private func handleRtmpPublish(_ notification: Notification) {
        let event = Event.from(notification)
        guard let data = event.data as? [String: Any?],
              let code = data["code"] as? String else { return }

        if code == "NetStream.Publish.Start" {
            connectTimeoutItem?.cancel()
            connectTimeoutItem = nil
            rtmpStream?.removeEventListener(
                .rtmpStatus,
                selector: #selector(rtmpPublishHandler(_:)),
                observer: self
            )
            isStarting  = false
            isStreaming = true
            let completion = streamStartCompletion
            streamStartCompletion = nil
            pendingStreamKey = nil
            completion?(true, nil)
        } else if code.contains("Error") || code.contains("Bad") || code.contains("Rejected") || code.contains("Denied") {
            failStart("串流發布失敗: \(code)")
        }
    }

    // Called on main thread from AppDelegate / platform channel.
    func stopStream(completion: @escaping () -> Void) {
        isStarting  = false
        isStreaming = false
        startToken  = UUID()  // invalidate any in-flight startStream closure

        connectTimeoutItem?.cancel()
        connectTimeoutItem = nil
        streamStartCompletion = nil
        pendingStreamKey = nil

        rtmpConnection.removeEventListener(
            .rtmpStatus,
            selector: #selector(rtmpConnectHandler(_:)),
            observer: self
        )
        rtmpStream?.removeEventListener(
            .rtmpStatus,
            selector: #selector(rtmpPublishHandler(_:)),
            observer: self
        )
        rtmpStream?.close()
        rtmpConnection.close()

        overlayLock.lock()
        celebrationStart = nil
        confettiParticles = []
        overlayLock.unlock()

        // Wait for session to fully stop before signalling Flutter.
        sessionQueue.async {
            if self.captureSession.isRunning {
                self.captureSession.stopRunning()
            }
            DispatchQueue.main.async {
                completion()
            }
        }
    }

    // MARK: - Goal celebration

    func triggerGoal() {
        let colors: [(CGFloat, CGFloat, CGFloat)] = [
            (1.0, 0.22, 0.22), (0.25, 0.60, 1.0), (1.0, 0.88, 0.10),
            (0.20, 0.85, 0.35), (1.0, 0.50, 0.10), (0.88, 0.25, 0.90),
            (1.0, 1.0, 1.0),   (0.10, 0.90, 0.90), (1.0, 0.60, 0.80),
        ]
        let particles: [Particle] = (0..<40).map { _ in
            let c = colors[Int.random(in: 0..<colors.count)]
            return Particle(
                x0:   CGFloat.random(in: 0...1920),
                y0:   -CGFloat.random(in: 0...500),
                vx:   CGFloat.random(in: -120...120),
                vy:   CGFloat.random(in: 180...520),
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

    // MARK: - Celebration overlay (capture queue — CoreGraphics + CoreText only)

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
        let gravity: CGFloat = 420

        if elapsed < 1.5 {
            let alpha = (1 - elapsed / 1.5) * 0.70
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: alpha))
            ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        }

        if elapsed < 2.0 {
            let pulsePeriod: CGFloat = 2.0 / 3.0
            let t = elapsed.truncatingRemainder(dividingBy: pulsePeriod) / pulsePeriod
            let pulseAlpha = sin(t * .pi) * 0.85
            ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: pulseAlpha))
            ctx.setLineWidth(20)
            ctx.stroke(CGRect(x: 0, y: 0, width: W, height: H).insetBy(dx: 10, dy: 10))
        }

        if elapsed < 2.0 {
            for p in particles {
                let px    = p.x0 + p.vx * elapsed
                let pyTop = p.y0 + p.vy * elapsed + 0.5 * gravity * elapsed * elapsed
                let pyCG  = H - pyTop
                guard pyCG > -40 && pyCG < H + 40 else { continue }
                ctx.saveGState()
                ctx.translateBy(x: px, y: pyCG)
                ctx.rotate(by: p.rot0 + p.rotV * elapsed)
                ctx.setFillColor(CGColor(red: p.r, green: p.g, blue: p.b, alpha: 0.92))
                ctx.fill(CGRect(x: -p.w / 2, y: -p.h / 2, width: p.w, height: p.h))
                ctx.restoreGState()
            }
        }

        let scale: CGFloat
        if elapsed < 0.4 {
            let t = elapsed / 0.4
            scale = 0.6 + (1 - (1 - t) * (1 - t)) * 2.4
        } else if elapsed < 0.8 {
            let t = (elapsed - 0.4) / 0.4
            scale = 3.0 - t * 1.7
        } else {
            scale = 1.3
        }
        let goalAlpha: CGFloat = elapsed > 2.5 ? max(0, 1 - (elapsed - 2.5) / 0.5) : 1.0
        guard goalAlpha > 0 else {
            return ctx.makeImage().map { CIImage(cgImage: $0) }
        }

        let fontSize: CGFloat = 140 * scale
        let font = CTFontCreateWithName("Impact" as CFString, fontSize, nil)

        for pass in 0...1 {
            let isOutline = pass == 0
            let color: CGColor = isOutline
                ? CGColor(red: 0, green: 0, blue: 0, alpha: goalAlpha)
                : CGColor(red: 1, green: 0.92, blue: 0.10, alpha: goalAlpha)
            let attrs: [CFString: Any] = [
                kCTFontAttributeName: font,
                kCTForegroundColorAttributeName: color,
            ]
            let attrStr = CFAttributedStringCreate(nil, "GOAL!" as CFString, attrs as CFDictionary)!
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

        if elapsed >= 0.2 && elapsed < 1.0 {
            let t = (elapsed - 0.2) / 0.8
            let beamX = -250 + t * (W + 500)
            let beamAlpha = sin(t * .pi) * 0.45
            ctx.saveGState()
            ctx.translateBy(x: beamX, y: H / 2)
            ctx.rotate(by: 0.32)
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
        guard let pixelBuffer = sampleBuffer.imageBuffer else { return }

        overlayLock.lock()
        let scoreOverlay = cachedOverlay
        let celStart     = celebrationStart
        let celParticles = confettiParticles
        overlayLock.unlock()

        let frameW      = CVPixelBufferGetWidth(pixelBuffer)
        let frameH      = CVPixelBufferGetHeight(pixelBuffer)
        let frameBounds = CGRect(x: 0, y: 0, width: frameW, height: frameH)

        var current = CIImage(cvPixelBuffer: pixelBuffer)

        if let overlay = scoreOverlay {
            compositeFilter.setValue(overlay.cropped(to: frameBounds), forKey: kCIInputImageKey)
            compositeFilter.setValue(current, forKey: kCIInputBackgroundImageKey)
            if let out = compositeFilter.outputImage { current = out }
        }

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

        ciContext.render(current, to: pixelBuffer, bounds: frameBounds, colorSpace: deviceRGB)
        rtmpStream?.append(sampleBuffer)
    }
}
