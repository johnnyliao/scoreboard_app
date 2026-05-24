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
        let padding: CGFloat = 14
        let lineGap: CGFloat = 6
        let cornerRadius: CGFloat = 10
        let offsetX: CGFloat = 20
        let offsetY: CGFloat = 20

        let nameFont = UIFont.systemFont(ofSize: 30, weight: .medium)
        let scoreFont = UIFont.monospacedDigitSystemFont(ofSize: 30, weight: .bold)

        let line1 = scoreLine(name: homeName, score: homeScore, nameFont: nameFont, scoreFont: scoreFont)
        let line2 = scoreLine(name: awayName, score: awayScore, nameFont: nameFont, scoreFont: scoreFont)
        let sz1 = line1.size()
        let sz2 = line2.size()

        let boxW = max(sz1.width, sz2.width) + padding * 2
        let boxH = sz1.height + lineGap + sz2.height + padding * 2
        let boxRect = CGRect(x: offsetX, y: offsetY, width: boxW, height: boxH)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let uiImage = renderer.image { _ in
            UIColor(red: 0, green: 0, blue: 0, alpha: 0.72).setFill()
            UIBezierPath(roundedRect: boxRect, cornerRadius: cornerRadius).fill()

            line1.draw(at: CGPoint(x: offsetX + padding, y: offsetY + padding))
            line2.draw(at: CGPoint(x: offsetX + padding,
                                   y: offsetY + padding + sz1.height + lineGap))
        }
        return CIImage(image: uiImage)
    }

    private func scoreLine(name: String, score: Int,
                            nameFont: UIFont, scoreFont: UIFont) -> NSAttributedString {
        let s = NSMutableAttributedString()
        s.append(NSAttributedString(
            string: "\(name)  ",
            attributes: [.font: nameFont, .foregroundColor: UIColor(white: 0.85, alpha: 1)]))
        s.append(NSAttributedString(
            string: "\(score)",
            attributes: [.font: scoreFont, .foregroundColor: UIColor.white]))
        return s
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

        overlayLock.lock()
        let overlay = cachedOverlay
        overlayLock.unlock()

        if let overlay = overlay {
            let frameW = CVPixelBufferGetWidth(pixelBuffer)
            let frameH = CVPixelBufferGetHeight(pixelBuffer)
            let frameBounds = CGRect(x: 0, y: 0, width: frameW, height: frameH)

            let videoImage = CIImage(cvPixelBuffer: pixelBuffer)

            // Overlay was built at exact pixel size (scale=1), crop to frame bounds to be safe
            let clippedOverlay = overlay.cropped(to: frameBounds)

            if let filter = CIFilter(name: "CISourceOverCompositing") {
                filter.setValue(clippedOverlay, forKey: kCIInputImageKey)
                filter.setValue(videoImage, forKey: kCIInputBackgroundImageKey)
                if let composited = filter.outputImage {
                    ciContext.render(composited, to: pixelBuffer,
                                     bounds: frameBounds,
                                     colorSpace: CGColorSpaceCreateDeviceRGB())
                }
            }
        }

        rtmpStream?.append(sampleBuffer)
    }
}
