import HarnessMonitorKit
import SwiftUI

struct SessionWindowInspector: View {
  let decision: Decision
  let isFilteredOut: Bool
  let decisionFilters: SessionDecisionFilterState
  @Bindable var decisionRuntime: SessionDecisionRuntime
  @Binding var visible: Bool
  @FocusState private var closeButtonFocused: Bool
  @Environment(\.accessibilityVoiceOverEnabled)
  private var voiceOverEnabled

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      if isFilteredOut {
        SessionFilteredDecisionNotice(filters: decisionFilters)
      }
      content
      Spacer(minLength: 0)
    }
    .padding(16)
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
        .font(.headline)
      Spacer()
      Button {
        hideInspector()
      } label: {
        Image(systemName: "xmark.circle.fill")
          .font(.title3)
          .foregroundStyle(.secondary)
      }
      .harnessPlainButtonStyle()
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
    SessionInspectorAnnouncer.announce(visible: false)
    visible = false
  }
}

public enum SessionInspectorAnnouncer {
  @MainActor
  public static func announce(visible: Bool) {
    let message = visible ? "Inspector shown" : "Inspector hidden"
    AccessibilityNotification.Announcement(message).post()
  }
}
