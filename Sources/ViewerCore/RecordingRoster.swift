import Foundation

/// Records every screen present during this session regardless of UI selection.
/// Old history is excluded until it becomes current again. A disappeared or
/// cleared screen keeps its dated last frame for the remainder of the recording.
public struct RecordingRoster {
    private var order: [String] = []
    private var retained: [String: RecordingScreen] = [:]

    public init() {}

    public mutating func update(currentIDs: [String], screens: [RecordingScreen]) -> [RecordingScreen] {
        let available = Dictionary(screens.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        for id in currentIDs where retained[id] == nil {
            guard let screen = available[id] else { continue }
            order.append(id)
            retained[id] = screen
        }
        for id in order {
            if let screen = available[id] {
                retained[id] = screen
            } else if let previous = retained[id] {
                retained[id] = RecordingScreen(id: previous.id, title: previous.title, image: previous.image,
                    sourceSize: previous.sourceSize, status: previous.isLive ? "画面已停止" : previous.status,
                    lastFrameAt: previous.lastFrameAt, isLive: false)
            }
        }
        return order.compactMap { retained[$0] }
    }
}
