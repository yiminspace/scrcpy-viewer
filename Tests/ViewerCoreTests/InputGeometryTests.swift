import CoreGraphics
import XCTest
@testable import ViewerCore

final class InputGeometryTests: XCTestCase {
    func testPortraitFrameHasHorizontalLetterboxAndMapsCenterToVideoPixels() throws {
        let view = CGSize(width: 1280, height: 720)
        XCTAssertEqual(InputGeometry.contentRect(viewSize: view, frameSize: CGSize(width: 864, height: 1920)),
                       CGRect(x: 478, y: 0, width: 324, height: 720))
        let center = try XCTUnwrap(InputGeometry.map(point: CGPoint(x: 640, y: 360),
                                                    viewSize: view, frameWidth: 864, frameHeight: 1920))
        XCTAssertEqual(center.x, 432)
        XCTAssertEqual(center.y, 960)
        XCTAssertEqual(center.width, 864)
        XCTAssertEqual(center.height, 1920)
        XCTAssertNil(InputGeometry.map(point: CGPoint(x: 477, y: 360), viewSize: view,
                                       frameWidth: 864, frameHeight: 1920))
    }

    func testLandscapeFrameHasVerticalLetterboxAfterRotation() throws {
        let view = CGSize(width: 1280, height: 720)
        XCTAssertEqual(InputGeometry.contentRect(viewSize: view, frameSize: CGSize(width: 1920, height: 864)),
                       CGRect(x: 0, y: 72, width: 1280, height: 576))
        let center = try XCTUnwrap(InputGeometry.map(point: CGPoint(x: 640, y: 360),
                                                    viewSize: view, frameWidth: 1920, frameHeight: 864))
        XCTAssertEqual(center.x, 960)
        XCTAssertEqual(center.y, 432)
        XCTAssertNil(InputGeometry.map(point: CGPoint(x: 640, y: 71), viewSize: view,
                                       frameWidth: 1920, frameHeight: 864))
    }

    func testContentEdgesNeverProduceOutOfRangeCoordinates() throws {
        let view = CGSize(width: 1280, height: 720)
        let origin = try XCTUnwrap(InputGeometry.map(point: CGPoint(x: 478, y: 0), viewSize: view,
                                                    frameWidth: 864, frameHeight: 1920))
        XCTAssertEqual(origin.x, 0)
        XCTAssertEqual(origin.y, 0)
        XCTAssertNil(InputGeometry.map(point: CGPoint(x: 802, y: 360), viewSize: view,
                                       frameWidth: 864, frameHeight: 1920))
        XCTAssertNil(InputGeometry.map(point: CGPoint(x: 640, y: 720), viewSize: view,
                                       frameWidth: 864, frameHeight: 1920))
        let edge = try XCTUnwrap(InputGeometry.map(point: CGPoint(x: 802, y: 720), viewSize: view,
                                                  frameWidth: 864, frameHeight: 1920, clampOutside: true))
        XCTAssertEqual(edge.x, 863)
        XCTAssertEqual(edge.y, 1919)
    }

    func testDragOutsideViewClampsSoReleaseCanBeDelivered() throws {
        let view = CGSize(width: 1280, height: 720)
        let left = try XCTUnwrap(InputGeometry.map(point: CGPoint(x: -100, y: 360), viewSize: view,
                                                  frameWidth: 864, frameHeight: 1920, clampOutside: true))
        XCTAssertEqual(left.x, 0)
        XCTAssertEqual(left.y, 960)
        let lowerRight = try XCTUnwrap(InputGeometry.map(point: CGPoint(x: 2000, y: 1000), viewSize: view,
                                                        frameWidth: 864, frameHeight: 1920, clampOutside: true))
        XCTAssertEqual(lowerRight.x, 863)
        XCTAssertEqual(lowerRight.y, 1919)
        XCTAssertNil(InputGeometry.map(point: CGPoint(x: -100, y: 360), viewSize: view,
                                       frameWidth: 864, frameHeight: 1920))
    }

    func testResizeKeepsSameRelativePointOnSameVideoPixel() throws {
        let before = try XCTUnwrap(InputGeometry.map(point: CGPoint(x: 559, y: 180),
            viewSize: CGSize(width: 1280, height: 720), frameWidth: 864, frameHeight: 1920))
        let after = try XCTUnwrap(InputGeometry.map(point: CGPoint(x: 279.5, y: 90),
            viewSize: CGSize(width: 640, height: 360), frameWidth: 864, frameHeight: 1920))
        XCTAssertEqual(before, after)
        XCTAssertEqual(after.x, 216)
        XCTAssertEqual(after.y, 480)
    }

    func testUsesDecodedFrameSizeRatherThanPhysicalDisplayOrBackingPixels() throws {
        // A 2x Retina view still supplies points; a max_size=1920 stream supplies 864x1920 pixels.
        let point = try XCTUnwrap(InputGeometry.map(point: CGPoint(x: 216, y: 480),
            viewSize: CGSize(width: 432, height: 960), frameWidth: 864, frameHeight: 1920))
        XCTAssertEqual(point.x, 432)
        XCTAssertEqual(point.y, 960)
        XCTAssertTrue(point.isForFrame(width: 864, height: 1920))
        XCTAssertFalse(point.isForFrame(width: 1080, height: 2400))
    }

    func testSavedGesturePositionCannotBeReusedAfterRotationOrResolutionChange() throws {
        let position = try XCTUnwrap(InputGeometry.map(point: CGPoint(x: 640, y: 360),
            viewSize: CGSize(width: 1280, height: 720), frameWidth: 864, frameHeight: 1920))
        XCTAssertFalse(position.isForFrame(width: 1920, height: 864))
        XCTAssertFalse(position.isForFrame(width: 432, height: 960))
        XCTAssertTrue(position.isForFrame(width: 864, height: 1920))
    }

    func testInvalidGeometryIsRejectedEvenWhenDragging() {
        let validView = CGSize(width: 1280, height: 720)
        for size in [CGSize.zero, CGSize(width: -1, height: 720),
                     CGSize(width: CGFloat.infinity, height: 720), CGSize(width: 1280, height: CGFloat.nan)] {
            XCTAssertNil(InputGeometry.contentRect(viewSize: size, frameSize: CGSize(width: 864, height: 1920)))
            XCTAssertNil(InputGeometry.map(point: .zero, viewSize: size, frameWidth: 864, frameHeight: 1920,
                                           clampOutside: true))
        }
        for width in [0, -1, 65536] {
            XCTAssertNil(InputGeometry.map(point: .zero, viewSize: validView, frameWidth: width, frameHeight: 1920))
        }
        XCTAssertNil(InputGeometry.map(point: CGPoint(x: CGFloat.nan, y: 1), viewSize: validView,
                                       frameWidth: 864, frameHeight: 1920, clampOutside: true))
        XCTAssertNil(InputGeometry.map(point: CGPoint(x: 1, y: CGFloat.infinity), viewSize: validView,
                                       frameWidth: 864, frameHeight: 1920, clampOutside: true))
    }
}
