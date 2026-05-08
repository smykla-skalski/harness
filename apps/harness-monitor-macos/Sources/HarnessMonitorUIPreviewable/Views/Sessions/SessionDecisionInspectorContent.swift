import HarnessMonitorKit
import SwiftUI

struct SessionDecisionInspectorContent: View {
  let decision: Decision
  @Bindable var runtime: SessionDecisionRuntime

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Picker("Inspector Tab", selection: $runtime.inspectorTab) {
        ForEach(SessionDecisionInspectorTab.allCases, id: \.self) { tab in
          Text(tab.title).tag(tab)
        }
      }
      .pickerStyle(.segmented)
      .accessibilityLabel("Decision inspector tab")

      switch runtime.inspectorTab {
      case .context:
        contextRows
      case .history:
        historyRows
      }
    }
  }

  private var contextRows: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(runtime.contextRows(for: decision)) { row in
        Text(row.value)
          .font(.caption)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  private var historyRows: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(runtime.historyRows(for: decision)) { row in
        VStack(alignment: .leading, spacing: 2) {
          Text(row.title)
            .font(.caption.weight(.semibold))
          Text(row.value)
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }
}
