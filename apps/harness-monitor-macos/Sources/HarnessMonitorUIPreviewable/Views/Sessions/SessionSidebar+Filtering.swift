import HarnessMonitorKit
import SwiftUI

struct SessionDecisionFilterControls: View {
  @Bindable var filters: SessionDecisionFilterState

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
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
