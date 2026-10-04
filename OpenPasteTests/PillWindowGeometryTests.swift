import AppKit
import Testing
@testable import OpenPaste

struct PillWindowGeometryTests {
    @Test
    func pillFloatsCenteredAboveBottomInset() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)

        let frame = PillWindowGeometry.frame(
            for: WindowDimensions(width: 920, height: 280),
            in: visibleFrame)

        #expect(frame == CGRect(x: 260, y: 18, width: 920, height: 280))
    }

    @Test
    func dimensionsAreClampedToAvailableDisplaySpace() {
        let visibleFrame = CGRect(x: 100, y: 50, width: 600, height: 300)

        let frame = PillWindowGeometry.frame(
            for: WindowDimensions(width: 920, height: 420),
            in: visibleFrame)

        #expect(frame.width == 568)
        #expect(frame.height == 282)
        #expect(frame.minX >= visibleFrame.minX)
        #expect(frame.maxX <= visibleFrame.maxX)
        #expect(frame.maxY <= visibleFrame.maxY)
    }

    @Test
    func compactModeChangesAutomaticallyAtHeightThreshold() {
        #expect(PillWindowGeometry.isCompact(height: 320))
        #expect(PillWindowGeometry.isCompact(height: 280))
        #expect(!PillWindowGeometry.isCompact(height: 321))
    }
}
