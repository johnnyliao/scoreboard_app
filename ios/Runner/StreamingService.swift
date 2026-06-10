import Foundation
import HaishinKit
import AVFoundation
import UIKit
import CoreImage
import CoreText
import VideoToolbox

final class ScoreboardOverlayEffect: VideoEffect {
    private weak var service: StreamingService?
    private let compositeFilter = CIFilter(name: "CISourceOverCompositing")!
    private let celebFilter = CIFilter(name: "CISourceOverCompositing")!

    init(service: StreamingService) {
        self.service = service
    }

    override func execute(_ image: CIImage, info: CMSampleBuffer?) -> CIImage {
        guard let service else { return image }

        let frameBounds = image.extent
        let frameW = Int(frameBounds.width)
        let frameH = Int(frameBounds.height)
        var current = image

        service.overlayLock.lock()
        let scoreOverlay = service.cachedOverlay
        let celStart = service.celebrationStart
        let celParticles = service.confettiParticles
        let celName = service.celebrationName
        service.overlayLock.unlock()

        if let overlay = scoreOverlay {
            compositeFilter.setValue(overlay.cropped(to: frameBounds), forKey: kCIInputImageKey)
            compositeFilter.setValue(current, forKey: kCIInputBackgroundImageKey)
            if let out = compositeFilter.outputImage {
                current = out
            }
        }

        if let start = celStart {
            let elapsed = CGFloat(-start.timeIntervalSinceNow)
            if elapsed >= CGFloat(service.celebrationDuration) {
                service.overlayLock.lock()
                if service.celebrationStart == start {
                    service.celebrationStart = nil
                    service.confettiParticles = []
                    service.celebrationName = nil
                }
                service.overlayLock.unlock()
            } else if let celOverlay = service.makeCelebrationOverlay(
                elapsed: elapsed,
                particles: celParticles,
                name: celName,
                frameW: frameW,
                frameH: frameH
            ) {
                celebFilter.setValue(celOverlay, forKey: kCIInputImageKey)
                celebFilter.setValue(current, forKey: kCIInputBackgroundImageKey)
                if let out = celebFilter.outputImage {
                    current = out
                }
            }
        }

        return current
    }
}

class StreamingService: NSObject {
    private let rtmpConnection = RTMPConnection()
    private var rtmpStream: RTMPStream?
    private(set) var previewView: UIView?
    var onDebugMessage: ((String) -> Void)?

    fileprivate let deviceRGB = CGColorSpaceCreateDeviceRGB()

    fileprivate let overlayLock = NSLock()
    fileprivate var cachedOverlay: CIImage?

    fileprivate var celebrationStart: Date?
    fileprivate let celebrationDuration: TimeInterval = 3.0
    fileprivate var confettiParticles: [Particle] = []
    fileprivate var celebrationName: String?

    /// Visual size multiplier for the goal celebration (particles, text, beam,
    /// border, shadow). 1.0 = pre-2026-05 size; current = 1.2 (+20%).
    fileprivate let celebrationScale: CGFloat = 1.2

    private var celebrationBuffer: UnsafeMutableRawPointer?
    private var celebrationFrameSize: CGSize = .zero

    private var pendingStreamKey: String?
    private var streamStartCompletion: ((Bool, String?) -> Void)?
    private var connectTimeoutItem: DispatchWorkItem?

    private var isStarting = false
    private var isStreaming = false {
        didSet {
            // Keep the screen awake while live (the user watches the match
            // without touching the phone); restore normal auto-lock when it
            // stops. didSet covers every transition: succeedStart sets true,
            // failStart/stopStream set false.
            let live = isStreaming
            DispatchQueue.main.async {
                UIApplication.shared.isIdleTimerDisabled = live
            }
        }
    }
    private var startToken = UUID()
    private var devicesAttached = false

    // ── 斷線重連 ──
    // 直播中 RTMP 斷線時,用同一組 url/key 自動重連並重新 publish。
    // onConnectionState 通知 Flutter: "reconnecting" / "reconnected" / "lost"。
    var onConnectionState: ((String) -> Void)?
    private var lastUrl: String?
    private var lastKey: String?
    private var isReconnecting = false
    private var reconnectAttempt = 0
    private let maxReconnectAttempts = 5
    private var reconnectWorkItem: DispatchWorkItem?
    private var reconnectTimeoutItem: DispatchWorkItem?

    fileprivate struct Particle {
        let x0: CGFloat
        let y0: CGFloat
        let vx: CGFloat
        let vy: CGFloat
        let r: CGFloat
        let g: CGFloat
        let b: CGFloat
        let w: CGFloat
        let h: CGFloat
        let rot0: CGFloat
        let rotV: CGFloat
    }

    override init() {
        super.init()
        setupStream()
    }

    deinit {
        if let buf = celebrationBuffer { free(buf) }
    }

    private func debug(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.onDebugMessage?(message)
        }
    }

    private func setupStream() {
        let stream = RTMPStream(connection: rtmpConnection)
        stream.sessionPreset = .hd1920x1080  // must come before frameRate
        stream.frameRate = 30
        stream.videoMixerSettings.mode = .offscreen  // required for the score VideoEffect

        var videoSettings = VideoCodecSettings()
        videoSettings.videoSize = CGSize(width: 1920, height: 1080)
        // ROOT CAUSE FIX: HaishinKit's default profileLevel is
        // kVTProfileLevel_H264_Baseline_3_1, whose max frame size is 1280x720.
        // 1920x1080 exceeds Level 3.1 -> VTCompressionSession silently emits no
        // frames -> YouTube receives no data. High profile + AutoLevel lets
        // VideoToolbox pick level 4.0+, which supports 1080p (YouTube's
        // recommended profile for 1080p).
        videoSettings.profileLevel = kVTProfileLevel_H264_High_AutoLevel as String
        videoSettings.bitRate = 4_500_000
        videoSettings.maxKeyFrameIntervalDuration = 2
        stream.videoSettings = videoSettings

        var audioSettings = AudioCodecSettings()
        audioSettings.bitRate = 128 * 1000
        stream.audioSettings = audioSettings

        stream.screen.size = CGSize(width: 1920, height: 1080)
        // Screen.frameRate DEFAULTS to 15 in HaishinKit 1.9.9. In offscreen mode
        // the encoded output fps is driven by the screen's choreographer
        // (preferredFramesPerSecond = Screen.frameRate), NOT by stream.frameRate
        // (which only sets the camera capture rate). Without this the stream went
        // out at 15fps despite stream.frameRate = 30. Must be set before
        // startRunning() (startRunning copies it into the choreographer).
        stream.screen.frameRate = 30
        stream.screen.startRunning()  // activates offscreen compositing for the VideoEffect
        stream.registerVideoEffect(ScoreboardOverlayEffect(service: self))

        let preview = MTHKView(frame: .zero)
        preview.videoGravity = .resizeAspectFill
        preview.attachStream(stream)

        rtmpStream = stream
        previewView = preview
    }

    private func attachDevicesIfNeeded() {
        guard !devicesAttached, let stream = rtmpStream else { return }
        devicesAttached = true

        let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        let mic = AVCaptureDevice.default(for: .audio)

        debug("attachCamera: \(camera != nil)")
        debug("attachAudio: \(mic != nil)")

        stream.attachCamera(camera)
        stream.attachAudio(mic)
        // Force landscape capture so the stream isn't portrait. Set AFTER
        // attachCamera so it applies to the live capture connection.
        // (If the image comes out upside-down, switch to .landscapeLeft.)
        stream.videoOrientation = .landscapeRight
    }

    func updateScore(
        homeName: String,
        homeScore: Int,
        awayName: String,
        awayScore: Int,
        clock: String = "",
        homeColorARGB: UInt32? = nil,
        awayColorARGB: UInt32? = nil
    ) {
        // Defaults match the Flutter side (home 橘 #F57C00, away 黃 #FDD835)
        // so a missing color arg never produces an unexpected look.
        let homeColor = homeColorARGB.map(Self.colorFromARGB) ?? UIColor(red: 0xF5/255.0, green: 0x7C/255.0, blue: 0x00/255.0, alpha: 1)
        let awayColor = awayColorARGB.map(Self.colorFromARGB) ?? UIColor(red: 0xFD/255.0, green: 0xD8/255.0, blue: 0x35/255.0, alpha: 1)
        let size = CGSize(width: 1920, height: 1080)
        let overlay = makeScoreOverlay(
            homeName: homeName,
            homeScore: homeScore,
            awayName: awayName,
            awayScore: awayScore,
            clock: clock,
            homeColor: homeColor,
            awayColor: awayColor,
            size: size
        )
        overlayLock.lock()
        cachedOverlay = overlay
        overlayLock.unlock()
    }

    /// Flutter `Color.value` is 32-bit ARGB. Convert to UIColor.
    static func colorFromARGB(_ argb: UInt32) -> UIColor {
        let a = CGFloat((argb >> 24) & 0xFF) / 255.0
        let r = CGFloat((argb >> 16) & 0xFF) / 255.0
        let g = CGFloat((argb >> 8) & 0xFF) / 255.0
        let b = CGFloat(argb & 0xFF) / 255.0
        return UIColor(red: r, green: g, blue: b, alpha: a)
    }

    /// Black or white text, whichever reads better on `bg` (perceived luminance).
    static func contrastingText(on bg: UIColor) -> UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        bg.getRed(&r, green: &g, blue: &b, alpha: &a)
        let luminance = 0.299 * r + 0.587 * g + 0.114 * b
        return luminance > 0.6 ? UIColor.black : UIColor.white
    }

    func startStream(url: String, key: String, completion: @escaping (Bool, String?) -> Void) {
        debug("startStream called")
        guard !isStarting && !isStreaming else {
            debug("start blocked: already starting or streaming")
            completion(false, "直播已在啟動中")
            return
        }

        let token = UUID()
        startToken = token
        isStarting = true
        isReconnecting = false
        reconnectAttempt = 0
        cancelReconnectTimers()
        streamStartCompletion = completion

        overlayLock.lock()
        celebrationStart = nil
        confettiParticles = []
        celebrationName = nil
        overlayLock.unlock()

        AVCaptureDevice.requestAccess(for: .video) { [weak self] videoOk in
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] audioOk in
                guard let self else { return }
                self.debug("permissions video=\(videoOk) audio=\(audioOk)")
                guard videoOk && audioOk else {
                    DispatchQueue.main.async {
                        self.failStart("需要攝影機和麥克風權限")
                    }
                    return
                }

                DispatchQueue.main.async {
                    guard self.isStarting && self.startToken == token else { return }

                    self.attachDevicesIfNeeded()
                    self.pendingStreamKey = key
                    self.lastUrl = url
                    self.lastKey = key

                    self.rtmpConnection.addEventListener(
                        .rtmpStatus,
                        selector: #selector(self.rtmpConnectHandler(_:)),
                        observer: self
                    )

                    self.rtmpStream?.addEventListener(
                        .rtmpStatus,
                        selector: #selector(self.rtmpPublishHandler(_:)),
                        observer: self
                    )

                    let timeout = DispatchWorkItem { [weak self] in
                        guard let self, self.streamStartCompletion != nil else { return }
                        self.debug("RTMP connect timeout")
                        self.failStart("RTMP 連線逾時，請確認網路")
                    }
                    self.connectTimeoutItem = timeout
                    DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: timeout)

                    self.debug("rtmpConnection.connect: \(url)")
                    self.rtmpConnection.connect(url)
                }
            }
        }
    }

    private func succeedStart() {
        connectTimeoutItem?.cancel()
        connectTimeoutItem = nil
        isStarting = false
        isStreaming = true
        let completion = streamStartCompletion
        streamStartCompletion = nil
        pendingStreamKey = nil
        completion?(true, nil)
    }

    private func failStart(_ message: String) {
        debug("failStart: \(message)")
        connectTimeoutItem?.cancel()
        connectTimeoutItem = nil
        cancelReconnectTimers()
        isReconnecting = false
        reconnectAttempt = 0

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
        devicesAttached = false
        streamStartCompletion = nil
        pendingStreamKey = nil

        DispatchQueue.main.async {
            completion?(false, message)
        }
    }

    @objc private func rtmpConnectHandler(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.handleRtmpConnect(notification)
        }
    }

    private func handleRtmpConnect(_ notification: Notification) {
        let event = Event.from(notification)
        guard let code = (event.data as? [String: Any])?["code"] as? String
            ?? notification.userInfo?["code"] as? String else {
            return
        }
        debug("rtmp connect status: \(code)")

        if code == "NetConnection.Connect.Success" {
            if isStarting {
                // 首次連線成功 → publish + 回報 Flutter。
                // 注意:不再移除 connect listener — 直播中要靠它偵測斷線
                // (NetConnection.Connect.Closed),否則連線掉了 App 不會知道。
                guard let key = pendingStreamKey else {
                    debug("missing pending stream key")
                    failStart("找不到串流金鑰")
                    return
                }
                debug("rtmp publish requested")
                rtmpStream?.publish(key)
                succeedStart()
            } else if isStreaming && isReconnecting {
                // 斷線重連成功 → 用同一把 key 重新 publish。
                // YouTube 端的 broadcast / liveStream 都還在,
                // 推流恢復後直播會自動續播,觀眾連結不變。
                guard let key = lastKey else { return }
                debug("reconnected, re-publishing")
                cancelReconnectTimers()
                isReconnecting = false
                reconnectAttempt = 0
                rtmpStream?.publish(key)
                notifyConnectionState("reconnected")
            }
        } else if code.contains("Failed") || code.contains("Rejected") || code == "NetConnection.Connect.Closed" {
            if isStarting {
                failStart("RTMP 連線失敗: \(code)")
            } else if isStreaming {
                // 直播中斷線(或重連嘗試本身失敗)→ 進入/繼續重連流程
                scheduleReconnect(reason: code)
            }
        }
    }

    // ── 斷線重連 ────────────────────────────────────────────

    /// 直播中 RTMP 斷線時呼叫。以遞增間隔(2s→4s→…上限 10s)重試,
    /// 最多 maxReconnectAttempts 次,全部失敗才放棄(streamLost)。
    private func scheduleReconnect(reason: String) {
        guard isStreaming else { return }
        // 同一次斷線可能連續收到 Closed 和 Failed 兩個事件;
        // 已有排程中的重連就不重複排,避免 attempt 灌水。
        guard reconnectWorkItem == nil else { return }
        // 清掉上一輪 attempt 留下的逾時保險(若有)
        reconnectTimeoutItem?.cancel()
        reconnectTimeoutItem = nil

        reconnectAttempt += 1
        guard reconnectAttempt <= maxReconnectAttempts else {
            streamLost(reason)
            return
        }

        isReconnecting = true
        notifyConnectionState("reconnecting")
        debug("RTMP 斷線(\(reason)),排程第 \(reconnectAttempt)/\(maxReconnectAttempts) 次重連…")

        let delay = min(Double(reconnectAttempt) * 2.0, 10.0)
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.isStreaming, self.isReconnecting else { return }
            self.reconnectWorkItem = nil
            guard let url = self.lastUrl else { return }
            self.debug("reconnect attempt \(self.reconnectAttempt): connecting")
            self.rtmpConnection.connect(url)

            // 單次嘗試的逾時保險:connect 卡死、15 秒內沒有任何
            // status 事件時視同失敗,直接推進下一次重連。
            let timeout = DispatchWorkItem { [weak self] in
                guard let self, self.isStreaming, self.isReconnecting else { return }
                self.debug("reconnect attempt timed out")
                self.scheduleReconnect(reason: "timeout")
            }
            self.reconnectTimeoutItem = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: timeout)
        }
        reconnectWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// 重連次數用盡:收掉所有資源並通知 Flutter 直播已中斷。
    private func streamLost(_ reason: String) {
        debug("重連失敗,放棄: \(reason)")
        cancelReconnectTimers()
        isReconnecting = false
        reconnectAttempt = 0
        isStreaming = false  // didSet 會順便恢復螢幕自動鎖

        // 先移除 listener 再 close,避免 close 觸發的 Closed 事件又進重連
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
        lastUrl = nil
        lastKey = nil

        notifyConnectionState("lost")
    }

    private func cancelReconnectTimers() {
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        reconnectTimeoutItem?.cancel()
        reconnectTimeoutItem = nil
    }

    private func notifyConnectionState(_ state: String) {
        DispatchQueue.main.async { [weak self] in
            self?.onConnectionState?(state)
        }
    }

    @objc private func rtmpPublishHandler(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.handleRtmpPublish(notification)
        }
    }

    private func handleRtmpPublish(_ notification: Notification) {
        let event = Event.from(notification)
        guard let code = (event.data as? [String: Any])?["code"] as? String
            ?? notification.userInfo?["code"] as? String else {
            return
        }
        debug("rtmp publish status: \(code)")
    }

    func stopStream(completion: @escaping () -> Void) {
        isStarting = false
        isStreaming = false
        startToken = UUID()

        cancelReconnectTimers()
        isReconnecting = false
        reconnectAttempt = 0
        lastUrl = nil
        lastKey = nil

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
        celebrationName = nil
        overlayLock.unlock()

        DispatchQueue.main.async {
            completion()
        }
    }

    func triggerGoal(playerName: String? = nil) {
        let colors: [(CGFloat, CGFloat, CGFloat)] = [
            (1.0, 0.22, 0.22), (0.25, 0.60, 1.0), (1.0, 0.88, 0.10),
            (0.20, 0.85, 0.35), (1.0, 0.50, 0.10), (0.88, 0.25, 0.90),
            (1.0, 1.0, 1.0), (0.10, 0.90, 0.90), (1.0, 0.60, 0.80),
        ]
        // Particle SIZES are scaled with celebrationScale (+20%); positions and
        // velocities stay tied to the 1920x1080 frame so they don't fly off.
        let cs = celebrationScale
        let particles: [Particle] = (0..<40).map { _ in
            let c = colors[Int.random(in: 0..<colors.count)]
            return Particle(
                x0: CGFloat.random(in: 0...1920),
                y0: -CGFloat.random(in: 0...500),
                vx: CGFloat.random(in: -120...120),
                vy: CGFloat.random(in: 180...520),
                r: c.0,
                g: c.1,
                b: c.2,
                w: CGFloat.random(in: 9...20) * cs,
                h: CGFloat.random(in: 14...26) * cs,
                rot0: CGFloat.random(in: 0...(2 * .pi)),
                rotV: CGFloat.random(in: -5...5)
            )
        }
        let cleanName = playerName?.trimmingCharacters(in: .whitespacesAndNewlines)
        overlayLock.lock()
        celebrationStart = Date()
        confettiParticles = particles
        celebrationName = (cleanName?.isEmpty == false) ? cleanName : nil
        overlayLock.unlock()
    }

    /// Broadcast-style horizontal scoreboard bar, top-left of the 1920x1080 frame.
    /// Layout (left → right):
    ///   [ MM:SS ][ HOME NAME ][ H ][ A ][ AWAY NAME ]
    /// Score cells are filled with team colors (blue home / red away); name cells
    /// carry a thin colored accent stripe on the bottom edge.
    private func makeScoreOverlay(
        homeName: String,
        homeScore: Int,
        awayName: String,
        awayScore: Int,
        clock: String,
        homeColor: UIColor,
        awayColor: UIColor,
        size: CGSize
    ) -> CIImage? {
        let originX: CGFloat = 48
        let originY: CGFloat = 48
        let barH: CGFloat = 90
        let cellPadX: CGFloat = 26
        let cornerRadius: CGFloat = 16
        let accentH: CGFloat = 5

        // homeColor / awayColor come from the Flutter UI (user-selectable).
        let barBG = UIColor(red: 0.04, green: 0.055, blue: 0.105, alpha: 0.86)                   // dark navy
        let clockTint = UIColor(white: 0, alpha: 0.30)
        let divider = UIColor(white: 1, alpha: 0.10)
        let border = UIColor(white: 1, alpha: 0.08)

        let nameFont = UIFont.systemFont(ofSize: 40, weight: .semibold)
        let scoreFont = UIFont.monospacedDigitSystemFont(ofSize: 48, weight: .heavy)
        let clockFont = UIFont.monospacedDigitSystemFont(ofSize: 40, weight: .bold)
        let white = UIColor.white
        // Score sits inside a team-colored cell; pick readable text per side
        // (e.g. white/yellow cells get dark text).
        let homeScoreText = Self.contrastingText(on: homeColor)
        let awayScoreText = Self.contrastingText(on: awayColor)

        let homeNameAttr = NSAttributedString(
            string: homeName,
            attributes: [.font: nameFont, .foregroundColor: white])
        let awayNameAttr = NSAttributedString(
            string: awayName,
            attributes: [.font: nameFont, .foregroundColor: white])
        let homeScoreAttr = NSAttributedString(
            string: "\(homeScore)",
            attributes: [.font: scoreFont, .foregroundColor: homeScoreText])
        let awayScoreAttr = NSAttributedString(
            string: "\(awayScore)",
            attributes: [.font: scoreFont, .foregroundColor: awayScoreText])
        let clockAttr = NSAttributedString(
            string: clock.isEmpty ? "00:00" : clock,
            attributes: [.font: clockFont, .foregroundColor: white])

        let clockCellW = ceil(clockAttr.size().width) + cellPadX * 2
        let homeNameCellW = ceil(homeNameAttr.size().width) + cellPadX * 2
        let awayNameCellW = ceil(awayNameAttr.size().width) + cellPadX * 2
        // Shared score-cell width keeps the center symmetric even when one side is 2-digit.
        let scoreCellW = max(74, max(ceil(homeScoreAttr.size().width),
                                     ceil(awayScoreAttr.size().width)) + 36)

        let totalW = clockCellW + homeNameCellW + scoreCellW + scoreCellW + awayNameCellW
        let barRect = CGRect(x: originX, y: originY, width: totalW, height: barH)
        let barPath = UIBezierPath(roundedRect: barRect, cornerRadius: cornerRadius)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let img = renderer.image { rc in
            let ctx = rc.cgContext

            // Bar background
            barBG.setFill()
            barPath.fill()

            // Clip subsequent fills/text to the rounded bar
            ctx.saveGState()
            barPath.addClip()

            var x = originX

            // Clock cell (slight tint to distinguish)
            let clockRect = CGRect(x: x, y: originY, width: clockCellW, height: barH)
            clockTint.setFill()
            ctx.fill(clockRect)
            self.drawCentered(clockAttr, in: clockRect)
            x += clockCellW

            // Home name + blue bottom accent
            let homeNameRect = CGRect(x: x, y: originY, width: homeNameCellW, height: barH)
            self.drawCentered(homeNameAttr, in: homeNameRect)
            homeColor.setFill()
            ctx.fill(CGRect(x: x, y: originY + barH - accentH,
                            width: homeNameCellW, height: accentH))
            x += homeNameCellW

            // Home score (blue cell, white bold)
            let homeScoreRect = CGRect(x: x, y: originY, width: scoreCellW, height: barH)
            homeColor.setFill()
            ctx.fill(homeScoreRect)
            self.drawCentered(homeScoreAttr, in: homeScoreRect)
            x += scoreCellW

            // Away score (red cell, white bold)
            let awayScoreRect = CGRect(x: x, y: originY, width: scoreCellW, height: barH)
            awayColor.setFill()
            ctx.fill(awayScoreRect)
            self.drawCentered(awayScoreAttr, in: awayScoreRect)
            x += scoreCellW

            // Away name + red bottom accent
            let awayNameRect = CGRect(x: x, y: originY, width: awayNameCellW, height: barH)
            self.drawCentered(awayNameAttr, in: awayNameRect)
            awayColor.setFill()
            ctx.fill(CGRect(x: x, y: originY + barH - accentH,
                            width: awayNameCellW, height: accentH))

            // Thin dividers at cell boundaries (over the colored cells too — subtle)
            divider.setFill()
            let boundaries: [CGFloat] = [
                originX + clockCellW,
                originX + clockCellW + homeNameCellW,
                originX + clockCellW + homeNameCellW + scoreCellW,
                originX + clockCellW + homeNameCellW + scoreCellW + scoreCellW,
            ]
            for bx in boundaries {
                ctx.fill(CGRect(x: bx - 0.5, y: originY, width: 1, height: barH))
            }

            ctx.restoreGState()

            // Crisp outer border
            border.setStroke()
            barPath.lineWidth = 1
            barPath.stroke()
        }
        return CIImage(image: img)
    }

    private func drawCentered(_ attr: NSAttributedString, in rect: CGRect) {
        let sz = attr.size()
        attr.draw(at: CGPoint(x: rect.midX - sz.width / 2,
                              y: rect.midY - sz.height / 2))
    }

    /// Draws `text` into a CGContext with a 4-corner outline shadow (offset
    /// passes for emphasis) followed by a single fill pass. CoreText-based
    /// (works on a manually-created CGContext, unlike UIKit's draw(at:)).
    private func drawShadowedText(
        _ text: String,
        font: CTFont,
        fillColor: CGColor,
        outlineColor: CGColor,
        baseline: CGPoint,
        shadowOffset: CGFloat,
        in ctx: CGContext
    ) {
        let outlineAttrs: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: outlineColor,
        ]
        let outlineLine = CTLineCreateWithAttributedString(
            CFAttributedStringCreate(nil, text as CFString, outlineAttrs as CFDictionary)!
        )
        for dx: CGFloat in [-shadowOffset, shadowOffset] {
            for dy: CGFloat in [-shadowOffset, shadowOffset] {
                ctx.textMatrix = .identity
                ctx.textPosition = CGPoint(x: baseline.x + dx, y: baseline.y + dy)
                CTLineDraw(outlineLine, ctx)
            }
        }
        let fillAttrs: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: fillColor,
        ]
        let fillLine = CTLineCreateWithAttributedString(
            CFAttributedStringCreate(nil, text as CFString, fillAttrs as CFDictionary)!
        )
        ctx.textMatrix = .identity
        ctx.textPosition = baseline
        CTLineDraw(fillLine, ctx)
    }

    fileprivate func makeCelebrationOverlay(
        elapsed: CGFloat,
        particles: [Particle],
        name: String?,
        frameW: Int,
        frameH: Int
    ) -> CIImage? {
        let needed = frameW * frameH * 4
        let targetSize = CGSize(width: frameW, height: frameH)
        if celebrationBuffer == nil || celebrationFrameSize != targetSize {
            if let old = celebrationBuffer { free(old) }
            celebrationBuffer = malloc(needed)
            celebrationFrameSize = targetSize
        }
        guard let buf = celebrationBuffer else { return nil }
        memset(buf, 0, needed)

        guard let ctx = CGContext(
            data: buf,
            width: frameW,
            height: frameH,
            bitsPerComponent: 8,
            bytesPerRow: frameW * 4,
            space: deviceRGB,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue |
                CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else {
            return nil
        }

        let W = CGFloat(frameW)
        let H = CGFloat(frameH)
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
            let pulseWidth = 20 * celebrationScale
            ctx.setLineWidth(pulseWidth)
            ctx.stroke(CGRect(x: 0, y: 0, width: W, height: H)
                .insetBy(dx: pulseWidth / 2, dy: pulseWidth / 2))
        }

        if elapsed < 2.0 {
            for p in particles {
                let px = p.x0 + p.vx * elapsed
                let pyTop = p.y0 + p.vy * elapsed + 0.5 * gravity * elapsed * elapsed
                let pyCG = H - pyTop
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

        // Text rendering — two-line if a player name is provided:
        //   <name>     (smaller, white)
        //   GOAL!      (big Impact, yellow w/ black stroke)
        // Otherwise: just "GOAL!" centered.
        let goalFontSize: CGFloat = 140 * celebrationScale * scale
        let goalFont = CTFontCreateWithName("Impact" as CFString, goalFontSize, nil)
        let shadowOffset: CGFloat = 3 * celebrationScale

        let cleanName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasName = (cleanName?.isEmpty == false)
        let nameFontSize: CGFloat = goalFontSize * 0.55
        // PingFangTC handles the Traditional Chinese roster cleanly; CoreText
        // falls back automatically if the named font isn't present.
        let nameFont: CTFont? = hasName
            ? CTFontCreateWithName("PingFangTC-Semibold" as CFString, nameFontSize, nil)
            : nil

        // Measure
        let goalMeasureLine = CTLineCreateWithAttributedString(
            CFAttributedStringCreate(nil, "GOAL!" as CFString,
                [kCTFontAttributeName: goalFont] as CFDictionary)!)
        var goalAsc: CGFloat = 0, goalDesc: CGFloat = 0
        let goalW = CGFloat(CTLineGetTypographicBounds(goalMeasureLine, &goalAsc, &goalDesc, nil))
        let goalH = goalAsc + goalDesc

        var nameW: CGFloat = 0, nameAsc: CGFloat = 0, nameDesc: CGFloat = 0, nameH: CGFloat = 0
        if hasName, let cleanName, let nameFont {
            let nameMeasureLine = CTLineCreateWithAttributedString(
                CFAttributedStringCreate(nil, cleanName as CFString,
                    [kCTFontAttributeName: nameFont] as CFDictionary)!)
            nameW = CGFloat(CTLineGetTypographicBounds(nameMeasureLine, &nameAsc, &nameDesc, nil))
            nameH = nameAsc + nameDesc
        }

        let gap: CGFloat = hasName ? nameH * 0.20 : 0
        let totalH = nameH + gap + goalH

        // CG coords: +y = up. Stack vertically centered at H/2.
        let goalBaselineY = H / 2 - totalH / 2 + goalDesc
        let goalX = (W - goalW) / 2

        drawShadowedText(
            "GOAL!",
            font: goalFont,
            fillColor: CGColor(red: 1, green: 0.92, blue: 0.10, alpha: goalAlpha),
            outlineColor: CGColor(red: 0, green: 0, blue: 0, alpha: goalAlpha),
            baseline: CGPoint(x: goalX, y: goalBaselineY),
            shadowOffset: shadowOffset,
            in: ctx
        )

        if hasName, let cleanName, let nameFont {
            let nameBaselineY = goalBaselineY + goalAsc + gap + nameDesc
            let nameX = (W - nameW) / 2
            drawShadowedText(
                cleanName,
                font: nameFont,
                fillColor: CGColor(red: 1, green: 1, blue: 1, alpha: goalAlpha),
                outlineColor: CGColor(red: 0, green: 0, blue: 0, alpha: goalAlpha * 0.85),
                baseline: CGPoint(x: nameX, y: nameBaselineY),
                shadowOffset: shadowOffset * 0.6,
                in: ctx
            )
        }

        if elapsed >= 0.2 && elapsed < 1.0 {
            let t = (elapsed - 0.2) / 0.8
            let beamX = -250 + t * (W + 500)
            let beamAlpha = sin(t * .pi) * 0.45
            ctx.saveGState()
            ctx.translateBy(x: beamX, y: H / 2)
            ctx.rotate(by: 0.32)
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: beamAlpha))
            let beamHalfW = 90 * celebrationScale
            ctx.fill(CGRect(x: -beamHalfW, y: -H, width: beamHalfW * 2, height: H * 2))
            ctx.restoreGState()
        }

        return ctx.makeImage().map { CIImage(cgImage: $0) }
    }
}
