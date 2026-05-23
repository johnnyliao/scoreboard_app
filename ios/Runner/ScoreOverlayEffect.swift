import Foundation
import HaishinKit
import UIKit
import CoreImage

class ScoreOverlayEffect: VideoEffect {
    private let overlayLock = NSLock()
    private var cachedOverlay: CIImage?
    private var cachedExtent = CGRect.zero
    private var isDirty = true

    // Score state — write from main thread, read from capture queue
    private var homeName: String = "主隊"
    private var homeScore: Int = 0
    private var awayName: String = "客隊"
    private var awayScore: Int = 0

    func update(homeName: String, homeScore: Int, awayName: String, awayScore: Int) {
        overlayLock.lock()
        self.homeName = homeName
        self.homeScore = homeScore
        self.awayName = awayName
        self.awayScore = awayScore
        isDirty = true
        overlayLock.unlock()
    }

    // Called on HaishinKit capture queue — must be fast, no main-thread UIKit
    override func execute(_ image: CIImage, info: CMSampleBuffer?) -> CIImage {
        let extent = image.extent

        overlayLock.lock()
        let needsRebuild = isDirty || extent != cachedExtent
        let hName = homeName
        let hScore = homeScore
        let aName = awayName
        let aScore = awayScore
        overlayLock.unlock()

        if needsRebuild {
            // UIGraphicsImageRenderer is thread-safe since iOS 10
            let overlay = makeOverlay(
                homeName: hName, homeScore: hScore,
                awayName: aName, awayScore: aScore,
                size: extent.size
            )
            overlayLock.lock()
            cachedOverlay = overlay
            cachedExtent = extent
            isDirty = false
            overlayLock.unlock()
        }

        overlayLock.lock()
        let overlay = cachedOverlay
        overlayLock.unlock()

        guard let overlay = overlay,
              let filter = CIFilter(name: "CISourceOverCompositing") else {
            return image
        }
        filter.setValue(overlay, forKey: kCIInputImageKey)
        filter.setValue(image, forKey: kCIInputBackgroundImageKey)
        return filter.outputImage ?? image
    }

    private func makeOverlay(homeName: String, homeScore: Int, awayName: String, awayScore: Int, size: CGSize) -> CIImage? {
        let barH: CGFloat = size.height * 0.1  // 10% of frame height
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
            let attrStr = NSAttributedString(string: text, attributes: attrs)
            let textSize = attrStr.size()
            attrStr.draw(at: CGPoint(
                x: (size.width - textSize.width) / 2,
                y: size.height - barH + (barH - textSize.height) / 2
            ))
        }
        return CIImage(image: uiImage)
    }
}
