import Foundation
import HaishinKit
import UIKit
import CoreImage

class ScoreOverlayEffect: NSObject, VideoEffect {
    private var cachedOverlay: CIImage?
    private let overlayLock = NSLock()
    private let ciContext = CIContext(options: [.workingColorSpace: NSNull()])

    func update(homeName: String, homeScore: Int, awayName: String, awayScore: Int, videoSize: CGSize) {
        let overlay = makeOverlay(
            homeName: homeName, homeScore: homeScore,
            awayName: awayName, awayScore: awayScore,
            size: videoSize
        )
        overlayLock.lock()
        cachedOverlay = overlay
        overlayLock.unlock()
    }

    func execute(_ buffer: CVPixelBuffer, info: CMSampleBuffer?) -> CVPixelBuffer {
        overlayLock.lock()
        let overlay = cachedOverlay
        overlayLock.unlock()

        guard let overlay = overlay else { return buffer }

        let ciImage = CIImage(cvPixelBuffer: buffer)
        let bufferExtent = ciImage.extent

        // Scale overlay to buffer dimensions if they differ
        var finalOverlay = overlay
        let overlayExtent = overlay.extent
        if abs(overlayExtent.width - bufferExtent.width) > 1 || abs(overlayExtent.height - bufferExtent.height) > 1 {
            let sx = bufferExtent.width / overlayExtent.width
            let sy = bufferExtent.height / overlayExtent.height
            finalOverlay = overlay.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        }

        let composited = finalOverlay.composited(over: ciImage)
        ciContext.render(composited, to: buffer)
        return buffer
    }

    private func makeOverlay(homeName: String, homeScore: Int, awayName: String, awayScore: Int, size: CGSize) -> CIImage? {
        let barH: CGFloat = 72
        let renderer = UIGraphicsImageRenderer(size: size)
        let uiImage = renderer.image { ctx in
            // Semi-transparent black bar at bottom (UIKit coords: y=0 is top)
            UIColor(red: 0, green: 0, blue: 0, alpha: 0.75).setFill()
            ctx.fill(CGRect(x: 0, y: size.height - barH, width: size.width, height: barH))

            let text = "\(homeName)  \(homeScore) - \(awayScore)  \(awayName)"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 36),
                .foregroundColor: UIColor.white
            ]
            let attrStr = NSAttributedString(string: text, attributes: attrs)
            let textSize = attrStr.size()
            attrStr.draw(at: CGPoint(
                x: (size.width - textSize.width) / 2,
                y: size.height - barH + (barH - textSize.height) / 2
            ))
        }

        guard let ciImage = CIImage(image: uiImage) else { return nil }

        // CIImage origin is bottom-left; UIKit origin is top-left.
        // Flip vertically so the bar stays at the bottom of the video frame.
        let flipped = ciImage.transformed(
            by: CGAffineTransform(scaleX: 1, y: -1)
                .translatedBy(x: 0, y: -size.height)
        )
        return flipped
    }
}
