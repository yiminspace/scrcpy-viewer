import CoreGraphics

/// Coordinates in the decoded video frame, including the dimensions the event was created for.
public struct InputPosition: Equatable, Sendable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public func isForFrame(width: Int, height: Int) -> Bool {
        self.width == width && self.height == height
    }
}

/// Maps view points to video pixels. View coordinates use a top-left origin,
/// matching an AppKit view whose `isFlipped` is true. Do not apply Retina scale.
public enum InputGeometry {
    public static func contentRect(viewSize: CGSize, frameSize: CGSize) -> CGRect? {
        guard valid(viewSize), valid(frameSize) else { return nil }
        let scale = min(viewSize.width / frameSize.width, viewSize.height / frameSize.height)
        let width = frameSize.width * scale
        let height = frameSize.height * scale
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        return CGRect(x: (viewSize.width - width) / 2, y: (viewSize.height - height) / 2,
                      width: width, height: height)
    }

    /// Ordinary presses ignore the letterbox. An ongoing drag/release may clamp
    /// to its edge so moving outside the image does not leave a finger pressed.
    public static func map(point: CGPoint, viewSize: CGSize, frameWidth: Int, frameHeight: Int,
                           clampOutside: Bool = false) -> InputPosition? {
        guard point.x.isFinite, point.y.isFinite,
              (1...65535).contains(frameWidth), (1...65535).contains(frameHeight),
              let rect = contentRect(viewSize: viewSize,
                                     frameSize: CGSize(width: frameWidth, height: frameHeight)) else { return nil }
        if !clampOutside && (point.x < rect.minX || point.x >= rect.maxX ||
                            point.y < rect.minY || point.y >= rect.maxY) { return nil }
        let viewX = min(rect.maxX, max(rect.minX, point.x)) - rect.minX
        let viewY = min(rect.maxY, max(rect.minY, point.y)) - rect.minY
        let x = min(frameWidth - 1, max(0, Int(viewX / rect.width * CGFloat(frameWidth))))
        let y = min(frameHeight - 1, max(0, Int(viewY / rect.height * CGFloat(frameHeight))))
        return InputPosition(x: x, y: y, width: frameWidth, height: frameHeight)
    }

    private static func valid(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
    }
}
