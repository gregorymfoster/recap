import Foundation

/// Guards the status transitions that can be delivered asynchronously by the
/// processing pipeline. In particular, a delayed progress tick must never
/// overwrite a terminal state such as `.ready` or `.error`.
public enum MeetingStatusTransition {
    public static func accepts(_ next: MeetingStatus, after current: MeetingStatus) -> Bool {
        guard case .transcribing = next else { return true }
        switch current {
        case .recording, .queued, .transcribing, .recovered:
            return true
        case .enhancing, .ready, .needsModel, .error:
            return false
        }
    }
}
