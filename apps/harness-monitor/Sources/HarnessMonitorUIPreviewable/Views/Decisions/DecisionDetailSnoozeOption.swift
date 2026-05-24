import Foundation

enum SnoozeOption: String, CaseIterable, Identifiable {
  case fifteenMinutes
  case oneHour
  case fourHours
  case oneDay

  var id: Self { self }

  var title: String {
    switch self {
    case .fifteenMinutes:
      "15 minutes"
    case .oneHour:
      "1 hour"
    case .fourHours:
      "4 hours"
    case .oneDay:
      "24 hours"
    }
  }

  var actionTitle: String {
    "Snooze for \(title)"
  }

  var duration: TimeInterval {
    switch self {
    case .fifteenMinutes:
      15 * 60
    case .oneHour:
      60 * 60
    case .fourHours:
      4 * 60 * 60
    case .oneDay:
      24 * 60 * 60
    }
  }
}
