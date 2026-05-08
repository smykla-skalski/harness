import HarnessMonitorKit
import SwiftUI

struct SessionDecisionFilterMetrics: Equatable {
  let verticalSpacing: CGFloat
  let horizontalSpacing: CGFloat
  let filterButtonSize: CGFloat

  init(fontScale: CGFloat) {
    let scale = SessionWindowFontScale.metricsScale(for: fontScale)
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
        Picker("Search scope", selection: $filters.scope) {
          ForEach(DecisionsSidebarSearchScope.allCases) { scope in
            Label(scope.label, systemImage: scope.systemImage)
              .tag(scope)
          }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(minWidth: 92)
        .help("Decision Search Scope")
        .accessibilityLabel("Decision Search Scope")
        .accessibilityValue(filters.scope.label)
        Menu {
          Button("All severities") {
            filters.severities.removeAll()
          }
          .disabled(filters.severities.isEmpty)
          Divider()
          ForEach(DecisionSeverity.allCases, id: \.self) { severity in
            Toggle(severity.rawValue.capitalized, isOn: severityBinding(severity))
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
      if hasActiveFilters {
        Text(filterSummary)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
    .dynamicTypeSize(.xSmall ... .accessibility5)
  }

  private func severityBinding(_ severity: DecisionSeverity) -> Binding<Bool> {
    Binding(
      get: { filters.severities.contains(severity) },
      set: { isSelected in
        if isSelected {
          filters.severities.insert(severity)
        } else {
          filters.severities.remove(severity)
        }
      }
    )
  }

  private var hasActiveFilters: Bool {
    !filters.query.isEmpty || !filters.severities.isEmpty || filters.scope != .summary
  }

  private var filterSummary: String {
    let severityText = filters.severities.map(\.rawValue).sorted().joined(separator: ", ")
    var segments: [String] = []
    if !filters.query.isEmpty {
      segments.append("Query: \(filters.query)")
    }
    if filters.scope != .summary || !filters.query.isEmpty {
      segments.append("scope: \(filters.scope.label)")
    }
    if !severityText.isEmpty {
      segments.append("severity: \(severityText)")
    }
    return segments.joined(separator: ", ")
  }
}
