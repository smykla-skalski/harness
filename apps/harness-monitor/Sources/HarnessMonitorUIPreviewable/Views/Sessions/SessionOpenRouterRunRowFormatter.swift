import HarnessMonitorKit
import SwiftUI

enum SessionOpenRouterRunRowFormatter {
  static func severityShape(for status: OpenRouterRunStatus) -> SessionSidebarSeverityShape {
    switch status {
    case .pending, .streaming:
      .dot
    case .failed:
      .alert
    case .idle, .cancelled:
      .none
    }
  }

  static func severityTint(for status: OpenRouterRunStatus) -> Color {
    switch status {
    case .pending:
      .gray
    case .streaming:
      .blue
    case .idle:
      .green
    case .cancelled:
      .gray
    case .failed:
      .red
    }
  }
}
