import HarnessMonitorKit
import SwiftUI

struct SessionDecisionInspectorContent: View {
  let decision: Decision
  @Bindable var runtime: SessionDecisionRuntime
  @Environment(\.fontScale)
  private var fontScale
  @SceneStorage("session.decisionInspectorTab")
  private var persistedInspectorTabRaw = ""

  private var metrics: SessionDecisionInspectorContentMetrics {
    SessionDecisionInspectorContentMetrics(fontScale: fontScale)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: metrics.sectionSpacing) {
      Picker("Inspector Tab", selection: $runtime.inspectorTab) {
        ForEach(SessionDecisionInspectorTab.allCases, id: \.self) { tab in
          Text(tab.title)
            .scaledFont(.body)
            .tag(tab)
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
    .onAppear {
      hydrateInspectorTabFromPersistedStorage()
    }
    .onChange(of: runtime.inspectorTab) { _, newValue in
      guard persistedInspectorTabRaw != newValue.rawValue else { return }
      persistedInspectorTabRaw = newValue.rawValue
    }
  }

  private func hydrateInspectorTabFromPersistedStorage() {
    guard let tab = SessionDecisionInspectorTab(rawValue: persistedInspectorTabRaw) else { return }
    guard runtime.inspectorTab != tab else { return }
    runtime.inspectorTab = tab
  }

  private var contextRows: some View {
    VStack(alignment: .leading, spacing: metrics.rowSpacing) {
      ForEach(runtime.contextRows(for: decision)) { row in
        Text(row.value)
          .scaledFont(.caption)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  private var historyRows: some View {
    VStack(alignment: .leading, spacing: metrics.rowSpacing) {
      ForEach(runtime.historyRows(for: decision)) { row in
        VStack(alignment: .leading, spacing: metrics.historyTitleSpacing) {
          Text(row.title)
            .scaledFont(.caption.weight(.semibold))
          Text(row.value)
            .scaledFont(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }
}

struct SessionDecisionInspectorContentMetrics: Equatable {
  let sectionSpacing: CGFloat
  let rowSpacing: CGFloat
  let historyTitleSpacing: CGFloat

  init(fontScale: CGFloat) {
    let scale = min(max(fontScale, 0.85), 1.8)
    sectionSpacing = max(12, 12 * min(scale, 1.35))
    rowSpacing = max(8, 8 * min(scale, 1.45))
    historyTitleSpacing = max(2, 2 * min(scale, 1.45))
  }
}
