import Foundation
import HaishinKit
import UIKit
import CoreImage

class ScoreOverlayEffect: VideoEffect {
    private var cachedOverlay: CIImage?
    private let overlayLock = NSLock()

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

    // HaishinKit 1.9.x: VideoEffect.execute takes CIImage, returns CIImage
    override func execute(_ image: CIImage, info: CMSampleBuffer?) -> CIImage {
        overlayLock.lock()
        let overlay = cachedOverlay
        overlayLock.unlock()

        guard let overlay = overlay else { return image }

        // Scale overlay to match frame size if needed
        let frameExtent = image.extent
        let overlayExtent = overlay.extent
        var finalOverlay = overlay
        if abs(overlayExtent.width - frameExtent.width) > 1 || abs(overlayExtent.height - frameExtent.height) > 1 {
            let sx = frameExtent.width / overlayExtent.width
            let sy = frameExtent.height / overlayExtent.height
            finalOverlay = overlay.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        }

        return finalOverlay.composited(over: image)
    }

    private func makeOverlay(homeName: String, homeScore: Int, awayName: String, awayScore: Int, size: CGSize) -> CIImage? {
        let barH: CGFloat = 72
        let renderer = UIGraphicsImageRenderer(size: size)
        let uiImage = renderer.image { ctx in
            // Black bar at bottom (UIKit: y=0 is top, so bottom = size.height - barH)
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
        // CIImage(image:) maps UIKit bottom → CIImage y=0 (bottom), no flip needed
        return CIImage(image: uiImage)
    }
}
