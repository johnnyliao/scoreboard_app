import Flutter
import UIKit
import AVFoundation
import HaishinKit

@main
@objc class AppDelegate: FlutterAppDelegate {
    private var streamingService: StreamingService?

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        configureAudioSession()

        let service = StreamingService()
        streamingService = service

        GeneratedPluginRegistrant.register(with: self)

        guard let controller = window?.rootViewController as? FlutterViewController else {
            return super.application(application, didFinishLaunchingWithOptions: launchOptions)
        }

        // Register camera preview PlatformView
        if let registry = self.registrar(forPlugin: "CameraPreview") {
            registry.register(
                CameraPreviewFactory(streamingService: service),
                withId: "com.scoreboard/camera_preview"
            )
        }

        // Register method channel
        let channel = FlutterMethodChannel(
            name: "com.scoreboard/streaming",
            binaryMessenger: controller.binaryMessenger
        )

        channel.setMethodCallHandler { [weak self] call, result in
            switch call.method {
            case "startStream":
                guard let args = call.arguments as? [String: Any],
                      let url = args["url"] as? String,
                      let key = args["key"] as? String else {
                    result(FlutterError(code: "INVALID_ARGS", message: "需要 url 和 key", details: nil))
                    return
                }
                guard let service = self?.streamingService else {
                    result(FlutterError(code: "NOT_INITIALIZED", message: "串流服務未就緒", details: nil))
                    return
                }
                service.startStream(url: url, key: key) { success, error in
                    if success {
                        result(true)
                    } else {
                        result(FlutterError(code: "STREAM_ERROR", message: error, details: nil))
                    }
                }
            case "stopStream":
                guard let service = self?.streamingService else {
                    result(FlutterError(code: "NOT_INITIALIZED", message: "串流服務未就緒", details: nil))
                    return
                }
                service.stopStream {
                    result(true)
                }
            case "updateScore":
                guard let args = call.arguments as? [String: Any] else {
                    result(nil); return
                }
                self?.streamingService?.updateScore(
                    homeName: args["homeName"] as? String ?? "主隊",
                    homeScore: args["homeScore"] as? Int ?? 0,
                    awayName: args["awayName"] as? String ?? "客隊",
                    awayScore: args["awayScore"] as? Int ?? 0
                )
                result(nil)
            case "triggerGoal":
                self?.streamingService?.triggerGoal()
                result(nil)
            default:
                result(FlutterMethodNotImplemented)
            }
        }

        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    private func configureAudioSession() {
        do {
            LBLogger.with(HaishinKitIdentifier).level = .trace
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.defaultToSpeaker, .allowBluetooth]
            )
            try session.setActive(true)
        } catch {
            NSLog("Failed to configure AVAudioSession: %@", error.localizedDescription)
        }
    }
}
