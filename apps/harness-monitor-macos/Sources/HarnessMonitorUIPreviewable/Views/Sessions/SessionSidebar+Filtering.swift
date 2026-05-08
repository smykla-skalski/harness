import HarnessMonitorKit
import SwiftUI

struct SessionDecisionFilterMetrics: Equatable {
  let verticalSpacing: CGFloat
  let horizontalSpacing: CGFloat
  let filterButtonSize: CGFloat

  init(fontScale: CGFloat) {
    let scale = min(max(fontScale, 0.85), 1.8)
    verticalSpacing = 6 * min(scale, 1.45)
    horizontalSpacing = HarnessMonitorTheme.spacingSM * min(scale, 1.35)
    filterButtonSize = scale >= 1.45 ? 44 : max(24, 24 * scale)
  }
}

struct SessionDecisionFilterControls: View {
  @Bindable var filters: SessionDecisionFilterState
  @Environment(\.fontScale)
  private var fontScale

  private var metrics: SessionDecisionFilterMetrics {
    SessionDecisionFilterMetrics(fontScale: fontScale)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: metrics.verticalSpacing) {
      HStack(spacing: metrics.horizontalSpacing) {
        TextField("Filter decisions", text: $filters.query)
          .textFieldStyle(.roundedBorder)
        Menu {
          ForEach(DecisionSeverity.allCases, id: \.self) { severity in
            Button {
              filters.toggle(severity)
            } label: {
              Label(
                severity.rawValue.capitalized,
                systemImage: filters.severities.contains(severity) ? "checkmark" : ""
              )
            }
          }
          Divider()
          Button("Clear Filters") {
            filters.clear()
          }
        } label: {
          Image(systemName: "line.3.horizontal.decrease.circle")
        }
        .menuIndicator(.hidden)
        .frame(width: metrics.filterButtonSize, height: metrics.filterButtonSize)
        .help("Decision Filters")
        .accessibilityLabel("Decision Filters")
      }
      if !filters.query.isEmpty || !filters.severities.isEmpty {
        Text(filterSummary)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
    .dynamicTypeSize(.xSmall ... .accessibility5)
  }

  private var filterSummary: String {
    let severityText = filters.severities.map(\.rawValue).sorted().joined(separator: ", ")
    if filters.query.isEmpty {
      return "Severity: \(severityText)"
    }
    if severityText.isEmpty {
      return "Query: \(filters.query)"
    }
    return "Query: \(filters.query), severity: \(severityText)"
  }
}
