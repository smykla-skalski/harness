import HarnessMonitorKit
import SwiftUI

enum SessionCodexRunRowFormatter {
  static func title(for run: CodexRunSnapshot) -> String {
    let head =
      run.prompt
      .split(whereSeparator: \.isNewline)
      .first
      .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
      ?? ""
    let fallback = run.displayName ?? "Codex agent"
    let prompt = head.isEmpty ? fallback : head
    let clipped = prompt.count > 48 ? "\(prompt.prefix(48))…" : prompt
    return "\(fallback) · \(run.mode.title) · \(clipped)"
  }

  static func severityShape(for status: CodexRunStatus) -> SessionSidebarSeverityShape {
    switch status {
    case .running, .queued:
      .dot
    case .waitingApproval:
      .alert
    case .failed:
      .alert
    case .completed, .cancelled:
      .none
    }
  }

  static func severityTint(for status: CodexRunStatus) -> Color {
    switch status {
    case .queued:
      .gray
    case .running:
      .blue
    case .waitingApproval:
      .orange
    case .completed:
      .green
    case .failed:
      .red
    case .cancelled:
      .gray
    }
  }
}
