import HarnessMonitorKit
import SwiftUI

extension HarnessMonitorAuditEvent {
  var auditSourceIcon: String {
    switch source {
    case "notifications":
      "bell.badge"
    case "supervisor":
      "checkmark.diamond"
    case "github":
      "shippingbox.circle"
    case "daemon":
      "terminal"
    case "taskBoard":
      "checklist"
    case "policy":
      "point.3.connected.trianglepath.dotted"
    default:
      "list.bullet.rectangle"
    }
  }

  var auditTint: Color {
    severity.auditSeverityTint ?? outcome.auditOutcomeTint ?? HarnessMonitorTheme.accent
  }

  var outcomeTint: Color {
    outcome.auditOutcomeTint ?? severity.auditSeverityTint ?? HarnessMonitorTheme.accent
  }

  var showsGitHubEdgeMark: Bool {
    source.caseInsensitiveCompare("github") == .orderedSame
      || category.auditTokenContains("github")
      || kind.auditTokenContains("github")
      || actionKey?.auditTokenContains("github") == true
      || actionKey?.lowercased().hasPrefix("reviews.") == true
      || relatedURLs.contains { $0.auditTokenContains("github.com") }
  }
}

extension String {
  var auditSeverityTint: Color? {
    switch lowercased() {
    case "error", "failure", "failed", "fatal":
      HarnessMonitorTheme.danger
    case "warning", "attention":
      HarnessMonitorTheme.caution
    case "success":
      HarnessMonitorTheme.success
    case "debug":
      HarnessMonitorTheme.secondaryInk
    default:
      nil
    }
  }

  var auditOutcomeTint: Color? {
    switch lowercased() {
    case "success", "completed", "complete", "approved", "merged", "applied", "updated",
      "dismissed":
      HarnessMonitorTheme.success
    case "waiting", "pending", "running", "in_progress", "in-progress", "deferred", "queued",
      "started":
      HarnessMonitorTheme.caution
    case "failure", "failed", "error", "blocked", "denied", "rejected", "cancelled",
      "canceled":
      HarnessMonitorTheme.danger
    case "warning", "attention":
      HarnessMonitorTheme.caution
    default:
      nil
    }
  }

  func auditTokenContains(_ token: String) -> Bool {
    range(of: token, options: [.caseInsensitive, .diacriticInsensitive]) != nil
  }

  var auditDisplayLabel: String {
    replacingOccurrences(of: "_", with: " ")
      .replacingOccurrences(of: "-", with: " ")
      .capitalized
  }
}
