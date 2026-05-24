import HarnessMonitorKit
import SwiftUI

// Inspector content is supplemental. Do not reintroduce detail-owned decision
// body, routing, or action fields into the context tab.
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
      runtime.prepareInspectorRows(for: decision)
    }
    .onChange(of: decision.id) { _, _ in
      runtime.prepareInspectorRows(for: decision)
    }
    .onChange(of: decision.contextJSON) { _, _ in
      runtime.prepareInspectorRows(for: decision)
    }
    .onChange(of: decision.statusRaw) { _, _ in
      runtime.prepareInspectorRows(for: decision)
    }
    .onChange(of: decision.snoozedUntil) { _, _ in
      runtime.prepareInspectorRows(for: decision)
    }
    .onChange(of: decision.resolutionJSON) { _, _ in
      runtime.prepareInspectorRows(for: decision)
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
    let presentation = runtime.inspectorRows(for: decision.id)
    return VStack(alignment: .leading, spacing: metrics.rowSpacing) {
      if presentation.isLoading {
        ProgressView()
          .controlSize(.small)
          .frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityLabel("Loading decision context")
      } else if presentation.contextRows.isEmpty {
        Text("No additional context")
          .scaledFont(.caption)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        ForEach(presentation.contextRows) { row in
          Text(row.value)
            .scaledFont(.caption)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
  }

  private var historyRows: some View {
    let presentation = runtime.inspectorRows(for: decision.id)
    return VStack(alignment: .leading, spacing: metrics.rowSpacing) {
      if presentation.isLoading {
        ProgressView()
          .controlSize(.small)
          .frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityLabel("Loading decision history")
      } else {
        ForEach(presentation.historyRows) { row in
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
}

struct SessionDecisionInspectorContentMetrics: Equatable {
  let sectionSpacing: CGFloat
  let rowSpacing: CGFloat
  let historyTitleSpacing: CGFloat

  init(fontScale: CGFloat) {
    let scale = SessionWindowFontScale.metricsScale(for: fontScale)
    sectionSpacing = max(12, 12 * min(scale, 1.35))
    rowSpacing = max(8, 8 * min(scale, 1.45))
    historyTitleSpacing = max(2, 2 * min(scale, 1.45))
  }
}
