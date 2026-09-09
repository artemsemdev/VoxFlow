import Foundation
import Testing
@testable import VoxFlow

/// `FlowBarPositionMath` pure geometry (backs `FlowBarPanel.present(on:)`) — tested without a real
/// `NSScreen`. `visibleFrame` below mirrors a typical MacBook display's visible area.
@Suite("FlowBarPosition")
struct GeneralFlowBarPositionTests {
    private static let visibleFrame = CGRect(x: 0, y: 0, width: 1440, height: 850)
    private static let size = CGSize(width: 200, height: 40)

    @Test("first presentation anchors per position (leftEdgeX nil)", arguments: [
        (FlowBarPosition.bottomCenter, CGPoint(x: 620, y: 24)),
        (FlowBarPosition.topCenter, CGPoint(x: 620, y: 786)),
        (FlowBarPosition.bottomLeft, CGPoint(x: 24, y: 24)),
        (FlowBarPosition.bottomRight, CGPoint(x: 1216, y: 24)),
    ])
    func firstPresentationAnchors(position: FlowBarPosition, expected: CGPoint) {
        let origin = FlowBarPositionMath.origin(size: Self.size, visibleFrame: Self.visibleFrame, position: position, leftEdgeX: nil)
        #expect(origin == expected)
    }

    @Test("an established leftEdgeX is echoed back (design 2a: grows right, left edge fixed)")
    func establishedLeftEdgeIsEchoedBack() {
        let origin = FlowBarPositionMath.origin(size: CGSize(width: 300, height: 40), visibleFrame: Self.visibleFrame,
                                                position: .bottomCenter, leftEdgeX: 100)
        #expect(origin.x == 100)
        #expect(origin.y == 24)
    }
}
