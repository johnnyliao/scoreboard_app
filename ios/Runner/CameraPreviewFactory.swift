import Flutter
import UIKit

class CameraPreviewFactory: NSObject, FlutterPlatformViewFactory {
    private let streamingService: StreamingService

    init(streamingService: StreamingService) {
        self.streamingService = streamingService
    }

    func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
        return CameraPreviewView(frame: frame, streamingService: streamingService)
    }

    func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
        return FlutterStandardMessageCodec.sharedInstance()
    }
}

class CameraPreviewView: NSObject, FlutterPlatformView {
    private let containerView: UIView

    init(frame: CGRect, streamingService: StreamingService) {
        containerView = UIView(frame: frame)
        super.init()

        if let preview = streamingService.previewView {
            preview.removeFromSuperview()  // detach from any previous container before re-parenting
            preview.frame = containerView.bounds
            preview.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            containerView.addSubview(preview)
        }
    }

    func view() -> UIView {
        return containerView
    }
}
