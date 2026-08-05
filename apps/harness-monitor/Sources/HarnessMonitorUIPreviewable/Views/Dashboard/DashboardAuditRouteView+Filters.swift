import Foundation
import HarnessMonitorKit

struct DashboardAuditFilters: Equatable {
  var source = DashboardAuditFilterConstants.allValue
  var category = DashboardAuditFilterConstants.allValue
  var outcome = DashboardAuditFilterConstants.allValue
  var severity = DashboardAuditFilterConstants.allValue
  var datePreset = DashboardAuditDatePreset.thirtyDays
  var actionKey = ""
  var subject = ""
  var searchText = ""

  func apply(to events: [HarnessMonitorAuditEvent]) -> [HarnessMonitorAuditEvent] {
    let cutoff = datePreset.cutoffDate
    let actionKeyFilter = normalized(actionKey)
    let subjectFilter = normalized(subject)
    let searchFilter = normalized(searchText)
    return events.filter { event in
      matches(source, event.source)
        && matches(category, event.category)
        && matches(outcome, event.outcome)
        && matches(severity, event.severity)
        && cutoff.map { event.recordedAt >= $0 } ?? true
        && matchesText(event.actionKey, actionKeyFilter)
        && matchesText(event.subject, subjectFilter)
        && matchesSearch(event, searchFilter)
    }
    .sorted(by: HarnessMonitorAuditEvent.auditEventSort)
  }

  private func matches(_ filter: String, _ value: String) -> Bool {
    filter == DashboardAuditFilterConstants.allValue || filter == value
  }

  private func matchesText(_ value: String?, _ filter: String?) -> Bool {
    guard let filter else { return true }
    return value?.range(of: filter, options: [.caseInsensitive, .diacriticInsensitive]) != nil
  }

  private func matchesSearch(_ event: HarnessMonitorAuditEvent, _ filter: String?) -> Bool {
    guard let filter else { return true }
    let haystacks = [
      event.title,
      event.summary,
      event.subject,
      event.actor,
      event.actionKey,
      event.legacyMessage,
    ]
    return haystacks.contains { value in
      value?.range(of: filter, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
  }

  private func normalized(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

enum DashboardAuditFilterField: Hashable {
  case actionKey
  case subject
  case searchText
}

enum DashboardAuditFilterConstants {
  static let allValue = "All"
}

enum DashboardAuditDatePreset: String, CaseIterable, Identifiable {
  case oneDay
  case sevenDays
  case fourteenDays
  case thirtyDays
  case ninetyDays
  case all

  var id: String { rawValue }

  var title: String {
    switch self {
    case .oneDay: "1d"
    case .sevenDays: "7d"
    case .fourteenDays: "14d"
    case .thirtyDays: "30d"
    case .ninetyDays: "90d"
    case .all: "All"
    }
  }

  var cutoffDate: Date? {
    let days: Int
    switch self {
    case .oneDay: days = 1
    case .sevenDays: days = 7
    case .fourteenDays: days = 14
    case .thirtyDays: days = 30
    case .ninetyDays: days = 90
    case .all: return nil
    }
    return Calendar.current.date(byAdding: .day, value: -days, to: .now)
  }
}
