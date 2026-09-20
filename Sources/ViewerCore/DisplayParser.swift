import Foundation

public enum DeviceParser {
    public static func parse(_ text: String) -> [AndroidDevice] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard parts.count >= 2, ["device", "offline", "unauthorized", "recovery", "sideload", "bootloader"].contains(parts[1]) else { return nil }
            let model = parts.first(where: { $0.hasPrefix("model:") }).map { String($0.dropFirst(6)).replacingOccurrences(of: "_", with: " ") } ?? parts[0]
            return AndroidDevice(serial: parts[0], model: model, connectionState: parts[1])
        }
    }
}

public enum DisplayParser {
    private struct PhysicalState {
        let name: String
        let uniqueID: String
        let state: String
        let owner: String
    }

    public static func parse(_ text: String, serial: String) -> [AndroidDisplay] {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        var physical: [PhysicalState] = []
        for line in lines where line.contains("DisplayDeviceInfo{") {
            guard let name = match(#"DisplayDeviceInfo\{"([^"]+)""#, line),
                  let state = match(#"\bstate ([A-Z_]+)"#, line) else { continue }
            physical.append(PhysicalState(name: name, uniqueID: match(#"uniqueId="([^"]+)""#, line) ?? "", state: state, owner: match(#"\bowner ([\w.]+)"#, line) ?? ""))
        }
        var displays: [Int: AndroidDisplay] = [:]
        // mOverrideDisplayInfo can retain ON after the output Surface is removed.
        // Parse base/logical IDs, but take state from the matching display device.
        for line in lines where line.contains("DisplayInfo{") && !line.contains("mOverrideDisplayInfo=") {
            guard let name = match(#"DisplayInfo\{"([^"]+)""#, line),
                  let idText = match(#"\bdisplayId (\d+)"#, line), let id = Int(idText) else { continue }
            let uniqueID = match(#"uniqueId "([^"]+)""#, line) ?? name
            let source = physical.first(where: { !$0.uniqueID.isEmpty && $0.uniqueID == uniqueID }) ?? physical.first(where: { $0.name == name })
            let state = source?.state ?? match(#"\bstate ([A-Z_]+)"#, line) ?? "UNKNOWN"
            let owner = source?.owner.nonEmpty ?? match(#"\bowner ([\w.]+)"#, line) ?? ""
            let dimensions = matches(#"\breal (\d+) x (\d+)"#, line)
            let display = AndroidDisplay(serial: serial, displayID: id, name: name, uniqueID: uniqueID, owner: owner, width: dimensions.first.flatMap(Int.init) ?? 0, height: dimensions.dropFirst().first.flatMap(Int.init) ?? 0, state: state)
            guard !display.isCaptureMirror else { continue }
            // Prefer the explicit base over a diagnostic duplicate elsewhere.
            if displays[id] == nil || line.contains("mBaseDisplayInfo=") { displays[id] = display }
        }
        return displays.values.sorted { $0.displayID < $1.displayID }
    }

    private static func match(_ pattern: String, _ text: String) -> String? { matches(pattern, text).first }
    private static func matches(_ pattern: String, _ text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let result = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return [] }
        return (1..<result.numberOfRanges).compactMap { Range(result.range(at: $0), in: text).map { String(text[$0]) } }
    }
}

private extension String { var nonEmpty: String? { isEmpty ? nil : self } }
