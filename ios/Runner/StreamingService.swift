import Foundation
import HaishinKit
import AVFoundation
import UIKit
import CoreImage

class StreamingService: NSObject {
    private let rtmpConnection = RTMPConnection()
    private var rtmpStream: RTMPStream?
    private(set) var previewView: UIView?

    // Our own capture session for video (we apply overlay before feeding HaishinKit)
    private let captureSession = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let captureQueue = DispatchQueue(label: "com.scoreboard.capture", qos: .userInteractive)
    private let ciContext = CIContext(options: [.workingColorSpace: NSNull()])

    // Overlay — built on main thread, read on capture queue
    private let overlayLock = NSLock()
    private var cachedOverlay: CIImage?
    private var overlaySize: CGSize = .zero

    override init() {
        super.init()
        setupCapture()
        setupStream()
    }

    // MARK: - Setup

    private func setupCapture() {
        captureSession.beginConfiguration()
        captureSession.sessionPreset = .hd1280x720

        if let cam = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
           let input = try? AVCaptureDeviceInput(device: cam),
           captureSession.canAddInput(input) {
            captureSession.addInput(input)
        }

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.setSampleBufferDelegate(self, queue: captureQueue)
        if captureSession.canAddOutput(videoOutput) {
            captureSession.addOutput(videoOutput)
            videoOutput.connection(with: .video)?.videoOrientation = .landscapeRight
        }

        captureSession.commitConfiguration()

        DispatchQueue.global(qos: .userInteractive).async {
            self.captureSession.startRunning()
        }
    }

    private func setupStream() {
        let stream = RTMPStream(connection: rtmpConnection)

        var videoSettings = VideoCodecSettings()
        videoSettings.videoSize = CGSize(width: 1280, height: 720)
        videoSettings.bitRate = 2_500_000
        stream.videoSettings = videoSettings

        var audioSettings = AudioCodecSettings()
        audioSettings.bitRate = 128 * 1000
        stream.audioSettings = audioSettings

        // HaishinKit handles audio capture; we handle video ourselves
        stream.attachAudio(AVCaptureDevice.default(for: .audio)) { _, _ in }

        let preview = MTHKView(frame: .zero)
        preview.videoGravity = .resizeAspectFill
        preview.attachStream(stream)

        self.rtmpStream = stream
        self.previewView = preview
    }

    // MARK: - Score

    // Called on main thread via Flutter platform channel
    func updateScore(homeName: String, homeScore: Int, awayName: String, awayScore: Int) {
        // Build overlay on main thread (UIKit-safe), then store for capture queue
        let size = CGSize(width: 1280, height: 720)
        let overlay = makeOverlay(
            homeName: homeName, homeScore: homeScore,
            awayName: awayName, awayScore: awayScore,
            size: size
        )
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
                    completion(false, "需要攝影機和麥克風權限")
                    return
                }
                DispatchQueue.main.async {
                    self.rtmpConnection.connect(url)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        self.rtmpStream?.publish(key)
                        completion(true, nil)
                    }
                }
            }
        }
    }

    func stopStream(completion: @escaping () -> Void) {
        rtmpStream?.close()
        rtmpConnection.close()
        completion()
    }

    // MARK: - Overlay drawing (called on main thread)

    private func makeOverlay(homeName: String, homeScore: Int,
                              awayName: String, awayScore: Int,
                              size: CGSize) -> CIImage? {
        let barH: CGFloat = size.height * 0.10
        let fontSize: CGFloat = barH * 0.55
        let renderer = UIGraphicsImageRenderer(size: size)
        let uiImage = renderer.image { ctx in
            UIColor(red: 0, green: 0, blue: 0, alpha: 0.75).setFill()
            ctx.fill(CGRect(x: 0, y: size.height - barH, width: size.width, height: barH))

            let text = "\(homeName)  \(homeScore) – \(awayScore)  \(awayName)"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: fontSize),
                .foregroundColor: UIColor.white
            ]
            let str = NSAttributedString(string: text, attributes: attrs)
            let sz = str.size()
            str.draw(at: CGPoint(
                x: (size.width - sz.width) / 2,
                y: size.height - barH + (barH - sz.height) / 2
            ))
        }
        return CIImage(image: uiImage)
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension StreamingService: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = sampleBuffer.imageBuffer else {
            rtmpStream?.append(sampleBuffer, track: 0)
            return
        }

        // Read cached overlay (built on main thread)
        overlayLock.lock()
        let overlay = cachedOverlay
        overlayLock.unlock()

        if let overlay = overlay {
            let videoImage = CIImage(cvPixelBuffer: pixelBuffer)

            // Scale overlay if frame size differs from overlay size
            var finalOverlay = overlay
            let frameSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer),
                                   height: CVPixelBufferGetHeight(pixelBuffer))
            if abs(overlaySize.width - frameSize.width) > 1 || abs(overlaySize.height - frameSize.height) > 1 {
                let sx = frameSize.width / overlaySize.width
                let sy = frameSize.height / overlaySize.height
                finalOverlay = overlay.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            }

            // Composite and render back into the same pixel buffer
            if let filter = CIFilter(name: "CISourceOverCompositing") {
                filter.setValue(finalOverlay, forKey: kCIInputImageKey)
                filter.setValue(videoImage, forKey: kCIInputBackgroundImageKey)
                if let composited = filter.outputImage {
                    CVPixelBufferLockBaseAddress(pixelBuffer, [])
                    ciContext.render(composited, to: pixelBuffer)
                    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
                }
            }
        }

        // Feed modified frame to HaishinKit (passthrough → encoder + preview)
        rtmpStream?.append(sampleBuffer, track: 0)
    }
}
