import HarnessMonitorKit
import SwiftUI

struct SessionWindowInspector: View {
  let selection: SessionSelection
  let selectedDecision: Decision?
  @Binding var visible: Bool
  @FocusState private var closeButtonFocused: Bool
  @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      content
      Spacer(minLength: 0)
    }
    .padding(16)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(.background)
    .accessibilityIdentifier(HarnessMonitorAccessibility.sessionWindowInspector)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Session inspector")
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
      .buttonStyle(.plain)
      .focused($closeButtonFocused)
      .keyboardShortcut(.cancelAction)
      .accessibilityIdentifier(HarnessMonitorAccessibility.sessionWindowInspectorCloseButton)
      .accessibilityLabel("Close inspector")
    }
  }

  @ViewBuilder private var content: some View {
    switch selection {
    case .decision:
      if let selectedDecision {
        DecisionDetailSummary(decision: selectedDecision)
      } else {
        ContentUnavailableView("Decision Not Available", systemImage: "exclamationmark.bubble")
      }
    default:
      ContentUnavailableView("No Inspector Context", systemImage: "sidebar.trailing")
    }
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
