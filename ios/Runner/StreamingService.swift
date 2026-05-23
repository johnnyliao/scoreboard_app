import Foundation
import HaishinKit
import AVFoundation
import UIKit

class StreamingService: NSObject {
    private let rtmpConnection = RTMPConnection()
    private var rtmpStream: RTMPStream?
    private(set) var previewView: UIView?
    private let scoreEffect = ScoreOverlayEffect()

    override init() {
        super.init()
        setupStream()
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

        stream.attachCamera(
            AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        ) { _, _ in }

        stream.attachAudio(
            AVCaptureDevice.default(for: .audio)
        ) { _, _ in }

        // Register effect now; execution only happens once offscreen mode is active
        stream.registerVideoEffect(scoreEffect)

        let preview = MTHKView(frame: .zero)
        preview.videoGravity = .resizeAspectFill
        preview.attachStream(stream)

        self.rtmpStream = stream
        self.previewView = preview
    }

    func updateScore(homeName: String, homeScore: Int, awayName: String, awayScore: Int) {
        scoreEffect.update(
            homeName: homeName, homeScore: homeScore,
            awayName: awayName, awayScore: awayScore
        )
    }

    func startStream(url: String, key: String, completion: @escaping (Bool, String?) -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] videoOk in
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] audioOk in
                guard let self = self else { return }
                guard videoOk && audioOk else {
                    completion(false, "需要攝影機和麥克風權限")
                    return
                }
                DispatchQueue.main.async {
                    // Switch to offscreen mode so VideoEffect.execute() is called,
                    // then start the Screen's display link and pixel buffer pool.
                    // Done here (not in init) so the stream is fully ready before
                    // the display link fires its first tick.
                    var mixerSettings = self.rtmpStream?.videoMixerSettings ?? IOVideoMixerSettings()
                    mixerSettings.mode = .offscreen
                    self.rtmpStream?.videoMixerSettings = mixerSettings
                    self.rtmpStream?.screen.startRunning()

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

        // Stop the offscreen rendering loop and revert to passthrough
        // so the camera preview continues working without the overhead.
        rtmpStream?.screen.stopRunning()
        var mixerSettings = rtmpStream?.videoMixerSettings ?? IOVideoMixerSettings()
        mixerSettings.mode = .passthrough
        rtmpStream?.videoMixerSettings = mixerSettings

        completion()
    }
}
