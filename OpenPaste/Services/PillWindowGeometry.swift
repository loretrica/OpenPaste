import CoreGraphics
import Foundation
import Observation

@MainActor
@Observable
final class PillWindowState {
    var isCompact = false

    func update(forHeight height: CGFloat) {
        isCompact = PillWindowGeometry.isCompact(height: height)
    }
}

enum PillWindowGeometry {
    static let compactHeightThreshold: CGFloat = 320
    static let horizontalMargin: CGFloat = 12
    static let maximumCompactCardSide: CGFloat = 220
    static let maximumFullCardSide: CGFloat = 320

    static func cardSide(availableHeight: CGFloat, isCompact: Bool) -> CGFloat {
        let maximumSide = isCompact ? maximumCompactCardSide : maximumFullCardSide
        return max(1, min(availableHeight, maximumSide))
    }

    static func frame(
        for dimensions: WindowDimensions,
        in visibleFrame: CGRect,
        bottomInset: CGFloat = 12
    ) -> CGRect {
        let safeWidth = max(1, visibleFrame.width - horizontalMargin * 2)
        let safeHeight = max(1, visibleFrame.height - bottomInset)
        let size = WindowDimensions(width: safeWidth, height: dimensions.height)
            .clamped(to: CGSize(width: safeWidth, height: safeHeight))
        return CGRect(
            x: visibleFrame.minX + (visibleFrame.width - size.width) / 2,
            y: visibleFrame.minY + bottomInset,
            width: size.width,
            height: size.height)
    }

    static func isCompact(height: CGFloat) -> Bool {
        height <= compactHeightThreshold
    }
}
