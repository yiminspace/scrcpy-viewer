import Foundation

public enum ScrcpyTouchAction: UInt8 { case down = 0, up = 1, move = 2, cancel = 3 }
public enum ScrcpyKeyAction: UInt8 { case down = 0, up = 1 }
public enum ScrcpyClipboardRequest: UInt8 { case none = 0, copy = 1, cut = 2 }

/// scrcpy 3.3.3 control protocol. No display-power or app-launch messages are exposed.
enum ScrcpyControlProtocol {
    static let maximumMessageSize = 1 << 18
    static func allowsControl(displayID: Int) -> Bool { displayID == 0 }

    struct Touch {
        let action: ScrcpyTouchAction
        let x: Int, y: Int, width: Int, height: Int
        let pressure: Float
        let buttons: UInt32, actionButton: UInt32
    }

    static func touch(_ event: Touch) -> Data? {
        guard validPosition(event.x, event.y, event.width, event.height), event.pressure.isFinite else { return nil }
        var bytes = Data([2, event.action.rawValue])
        append(UInt64.max - 1, bytes: 8, to: &bytes) // Generic finger, signed pointer ID -2.
        position(event.x, event.y, event.width, event.height, to: &bytes)
        let pressure = event.action == .up || event.action == .cancel ? 0 : min(1, max(0, event.pressure))
        append(UInt64(min(65535, Int(pressure * 65536))), bytes: 2, to: &bytes)
        append(UInt64(event.actionButton), bytes: 4, to: &bytes)
        append(UInt64(event.buttons), bytes: 4, to: &bytes)
        return bytes
    }

    static func scroll(x: Int, y: Int, width: Int, height: Int,
                       horizontal: Float, vertical: Float, buttons: UInt32) -> Data? {
        guard validPosition(x, y, width, height), horizontal.isFinite, vertical.isFinite else { return nil }
        var bytes = Data([3])
        position(x, y, width, height, to: &bytes)
        for value in [horizontal, vertical] {
            let fixed = Int16(min(32767, max(-32768, Int(min(16, max(-16, value)) * 2048))))
            append(UInt64(UInt16(bitPattern: fixed)), bytes: 2, to: &bytes)
        }
        append(UInt64(buttons), bytes: 4, to: &bytes)
        return bytes
    }

    static func key(action: ScrcpyKeyAction, keyCode: UInt32, repeatCount: UInt32, metaState: UInt32) -> Data {
        var data = Data([0, action.rawValue])
        for value in [keyCode, repeatCount, metaState] { append(UInt64(value), bytes: 4, to: &data) }
        return data
    }

    static func text(_ text: String) -> Data? {
        let utf8 = Data(text.utf8)
        guard !utf8.isEmpty, utf8.count <= 300 else { return nil }
        var data = Data([1]); append(UInt64(utf8.count), bytes: 4, to: &data); data.append(utf8)
        return data
    }

    static func clipboard(_ text: String, paste: Bool, sequence: UInt64) -> Data? {
        let utf8 = Data(text.utf8)
        guard utf8.count <= maximumMessageSize - 14 else { return nil }
        var data = Data([9]); append(sequence, bytes: 8, to: &data)
        data.append(paste ? 1 : 0); append(UInt64(utf8.count), bytes: 4, to: &data); data.append(utf8)
        return data
    }

    static func requestClipboard(_ request: ScrcpyClipboardRequest) -> Data { Data([8, request.rawValue]) }

    static func integer(_ data: Data) -> UInt64 { data.reduce(0) { ($0 << 8) | UInt64($1) } }

    private static func validPosition(_ x: Int, _ y: Int, _ width: Int, _ height: Int) -> Bool {
        (1...65535).contains(width) && (1...65535).contains(height) &&
        (0..<width).contains(x) && (0..<height).contains(y)
    }

    private static func position(_ x: Int, _ y: Int, _ width: Int, _ height: Int, to data: inout Data) {
        append(UInt64(x), bytes: 4, to: &data); append(UInt64(y), bytes: 4, to: &data)
        append(UInt64(width), bytes: 2, to: &data); append(UInt64(height), bytes: 2, to: &data)
    }

    private static func append(_ value: UInt64, bytes: Int, to data: inout Data) {
        for offset in (0..<bytes).reversed() { data.append(UInt8((value >> (offset * 8)) & 255)) }
    }
}
