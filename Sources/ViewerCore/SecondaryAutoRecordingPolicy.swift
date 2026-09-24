/// Decides when an opted-in recording follows the presence of secondary displays.
/// The caller owns recording, device connectivity and shutdown, and reports the
/// current recorder state on each evaluation.
public struct SecondaryAutoRecordingPolicy: Sendable {
    public enum Action: Equatable, Sendable {
        case none
        case start
        case stop
    }

    private var isSuppressed = false
    private var startRequested = false

    public init() {}

    /// A manual stop or recording failure must not immediately restart the same
    /// secondary-display session. Observing no secondary rearms the policy.
    public mutating func suppressUntilNoSecondary() {
        isSuppressed = true
        startRequested = false
    }

    /// Use when changing devices or explicitly reconfiguring automatic recording.
    public mutating func reset() {
        isSuppressed = false
        startRequested = false
    }

    public mutating func action(enabled: Bool, hasSecondary: Bool, hasFrame: Bool,
                                recordingIsAutomatic: Bool, isRecording: Bool,
                                isFinishing: Bool) -> Action {
        // Observe the absence even while a previous file is being finalized, so
        // a secondary that returns during saving can start once saving completes.
        if !hasSecondary {
            isSuppressed = false
            startRequested = false
        }
        if !enabled || isRecording { startRequested = false }

        guard !isFinishing else { return .none }
        if isRecording {
            return recordingIsAutomatic && (!enabled || !hasSecondary) ? .stop : .none
        }
        guard enabled, hasSecondary, hasFrame, !isSuppressed, !startRequested else {
            return .none
        }
        startRequested = true
        return .start
    }
}
