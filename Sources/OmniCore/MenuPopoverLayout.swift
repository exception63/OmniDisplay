import Foundation

/// AppKit global coordinates (points, origin at bottom-left). Never CG pixels.
public enum MenuPopoverLayout {
    public static func screenIndex(anchor: CGRect, frames: [CGRect]) -> Int? {
        guard anchor.width > 0, anchor.height > 0 else { return nil }
        let center = CGPoint(x: anchor.midX, y: anchor.midY)
        return frames.firstIndex { $0.contains(center) }
    }
    public static func contentSize(anchor: CGRect, visibleFrame: CGRect, displayCount: Int) -> CGSize? {
        // Leave room for the system popover's arrow, chrome and screen margin.
        let availableHeight = min(anchor.minY, visibleFrame.maxY) - visibleFrame.minY - 32
        let availableWidth = visibleFrame.width - 32
        guard availableHeight >= 170, availableWidth >= 240 else { return nil }
        return CGSize(width: min(340, availableWidth), height: min(150 + CGFloat(max(1, displayCount)) * 62, 480, availableHeight))
    }
}
