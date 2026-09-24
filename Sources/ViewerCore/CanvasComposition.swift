import CoreGraphics
import CoreText
import Foundation

/// A tightly packed, equally tall row shared by screenshots and recordings.
public enum CanvasComposition {
    /// Dimensions are even for video encoders. Scaling never exceeds the smallest source height.
    public static func size(for screens: [RecordingScreen], maximumHeight: Int = 720,
                            maximumWidth: Int = 2560) -> CGSize {
        guard !screens.isEmpty, maximumHeight >= 2, maximumWidth >= 2 else { return .zero }
        let sources = screens.map(sourceSize)
        let ratioSum = sources.reduce(CGFloat.zero) { $0 + $1.width / $1.height }
        let sourceHeight = sources.map(\.height).min() ?? 720
        let maxWidth = CGFloat(min(maximumWidth, 8192))
        let height = min(CGFloat(min(maximumHeight, 8192)), sourceHeight, maxWidth / ratioSum)
        let evenHeight = max(2, floor(height / 2) * 2)
        let evenWidth = max(2, min(floor(maxWidth / 2) * 2, (evenHeight * ratioSum / 2).rounded() * 2))
        return CGSize(width: evenWidth, height: evenHeight)
    }

    public static func image(screens: [RecordingScreen], maximumHeight: Int = 720,
                             maximumWidth: Int = 2560) throws -> CGImage {
        let dimensions = size(for: screens, maximumHeight: maximumHeight, maximumWidth: maximumWidth)
        guard dimensions.width > 0, dimensions.height > 0 else { throw CanvasRecordingError.noFrames }
        guard let context = CGContext(data: nil, width: Int(dimensions.width), height: Int(dimensions.height),
            bitsPerComponent: 8, bytesPerRow: Int(dimensions.width) * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CanvasRecordingError.encoding("无法合成画面")
        }
        draw(screens, in: context, size: dimensions)
        guard let result = context.makeImage() else { throw CanvasRecordingError.encoding("无法生成画面") }
        return result
    }

    /// Caller must keep the composition aspect stable for a fixed-size recording segment.
    static func draw(_ screens: [RecordingScreen], in context: CGContext, size: CGSize) {
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        guard !screens.isEmpty else { return }
        let ratios = screens.map { sourceSize($0).width / sourceSize($0).height }
        let total = ratios.reduce(0, +)
        var accumulated = CGFloat.zero
        var left = CGFloat.zero
        context.interpolationQuality = .high
        for (index, screen) in screens.enumerated() {
            accumulated += ratios[index]
            // Share each rounded boundary so adjacent screens cannot leave a pixel-wide gap.
            let right = index == screens.count - 1 ? size.width : (size.width * accumulated / total).rounded()
            let rect = CGRect(x: left, y: 0, width: right - left, height: size.height)
            if let image = screen.image { context.draw(image, in: rect) }
            if screen.image == nil || !screen.isLive { drawStatus(screen, in: rect, context: context) }
            left = right
        }
    }

    static func sourceSize(_ screen: RecordingScreen) -> CGSize {
        let size = screen.image.map { CGSize(width: $0.width, height: $0.height) } ?? screen.sourceSize
        guard size.width.isFinite, size.height.isFinite, size.width >= 2, size.height >= 2 else {
            return CGSize(width: 720, height: 1280)
        }
        return size
    }

    private static func drawStatus(_ screen: RecordingScreen, in rect: CGRect, context: CGContext) {
        guard rect.width > 0 else { return }
        let fontSize = min(12, max(8, rect.height / 60))
        let inset = min(8, max(2, rect.width / 30))
        let lineHeight = fontSize + 5
        let hasDate = screen.image != nil && screen.lastFrameAt != nil
        let overlayHeight = min(rect.height, lineHeight * (hasDate ? 2 : 1) + inset * 2)
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: rect)
        context.setFillColor(CGColor(gray: 0, alpha: 0.68))
        context.fill(CGRect(x: rect.minX, y: 0, width: rect.width, height: overlayHeight))
        let status = screen.image == nil ? "\(screen.status) · 尚无画面" : "\(screen.status) · 保留最后画面"
        drawText(status, rect: CGRect(x: rect.minX + inset, y: overlayHeight - inset - lineHeight,
            width: max(1, rect.width - inset * 2), height: lineHeight), size: fontSize, context: context)
        if hasDate, let date = screen.lastFrameAt {
            drawText(date.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits)
                .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)),
                rect: CGRect(x: rect.minX + inset, y: inset, width: max(1, rect.width - inset * 2),
                             height: lineHeight), size: fontSize - 1, context: context)
        }
    }

    private static func drawText(_ text: String, rect: CGRect, size: CGFloat, context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: rect)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, size, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        context.textPosition = CGPoint(x: rect.minX, y: rect.minY + max(0, (rect.height - size) / 2) + 2)
        CTLineDraw(line, context)
    }
}
