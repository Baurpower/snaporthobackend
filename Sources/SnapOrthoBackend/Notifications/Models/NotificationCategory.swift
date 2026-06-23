import Vapor

enum NotificationCategory: String, Codable, CaseIterable, Sendable {
    case system    = "system"
    case learning  = "learning"
    case caseprep  = "caseprep"
    case brobot    = "brobot"
    case reminders = "reminders"
    case product   = "product"

    /// Default opt-in state when no preference row exists yet.
    /// Product/marketing notifications require explicit opt-in.
    var defaultEnabled: Bool {
        switch self {
        case .product: return false
        default: return true
        }
    }

    // system notifications bypass frequency caps
    var bypassesFrequencyCap: Bool { self == .system }
}
