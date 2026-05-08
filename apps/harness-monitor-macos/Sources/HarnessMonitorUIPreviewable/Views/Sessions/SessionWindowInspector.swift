import HarnessMonitorKit
import SwiftUI

struct SessionWindowInspectorMetrics: Equatable {
  let spacing: CGFloat
  let padding: CGFloat
  let closeButtonMinSize: CGFloat

  init(fontScale: CGFloat) {
    let scale = SessionWindowFontScale.metricsScale(for: fontScale)
    spacing = 12 * min(scale, 1.35)
    padding = 16 * min(scale, 1.3)
    closeButtonMinSize = scale >= 1.45 ? 44 : 0
  }
}

struct SessionWindowInspector: View {
  let decision: Decision
  let isFilteredOut: Bool
  let decisionFilters: SessionDecisionFilterState
  @Bindable var decisionRuntime: SessionDecisionRuntime
  @Binding var visible: Bool
  @Binding var preferredVisible: Bool
  @FocusState private var closeButtonFocused: Bool
  @Environment(\.accessibilityVoiceOverEnabled)
  private var voiceOverEnabled
  @Environment(\.fontScale)
  private var fontScale

  private var metrics: SessionWindowInspectorMetrics {
    SessionWindowInspectorMetrics(fontScale: fontScale)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: metrics.spacing) {
      header
      if isFilteredOut {
        SessionFilteredDecisionNotice(filters: decisionFilters)
      }
      content
      Spacer(minLength: 0)
    }
    .padding(metrics.padding)
    .dynamicTypeSize(.xSmall ... .accessibility5)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(.background)
    .accessibilityElement(children: .contain)
    .accessibilityTestProbe(
      HarnessMonitorAccessibility.sessionWindowInspector,
      label: "Session inspector"
    )
    .onAppear {
      if voiceOverEnabled {
        closeButtonFocused = true
      }
    }
    .onKeyPress(.escape) {
      hideInspector()
      return .handled
    }
  }

  private var header: some View {
    HStack {
      Text("Inspector")
        .scaledFont(.headline)
      Spacer()
      Button {
        hideInspector()
      } label: {
        Image(systemName: "xmark.circle.fill")
          .scaledFont(.title3)
          .foregroundStyle(.secondary)
      }
      .harnessPlainButtonStyle()
      .frame(minWidth: metrics.closeButtonMinSize, minHeight: metrics.closeButtonMinSize)
      .focused($closeButtonFocused)
      .keyboardShortcut(.cancelAction)
      .accessibilityIdentifier(HarnessMonitorAccessibility.sessionWindowInspectorCloseButton)
      .accessibilityLabel("Close inspector")
    }
  }

  private var content: some View {
    SessionDecisionInspectorContent(
      decision: decision,
      runtime: decisionRuntime
    )
  }

  private func hideInspector() {
    preferredVisible = false
    guard visible else { return }
    visible = false
    SessionInspectorAnnouncer.announce(visible: false)
  }
}

public enum SessionInspectorAnnouncer {
  @MainActor
  public static func announce(visible: Bool) {
    let message = visible ? "Inspector shown" : "Inspector hidden"
    AccessibilityNotification.Announcement(message).post()
  }
}
