import SwiftUI

struct SessionPolicyCanvasRedirectView: View {
  @Environment(\.openDashboardRoute)
  private var openDashboardRoute
  @State private var hasRequestedOpen = false

  var body: some View {
    SessionDetailEmptySurface {
      ContentUnavailableView(
        "Policies Open in Dashboard",
        systemImage: "rectangle.on.rectangle",
        description: Text(
          "Policy canvases now live in Dashboard > Policies so every session window reuses the same editor."
        )
      )
      .overlay(alignment: .bottom) {
        Button {
          openPoliciesRoute()
        } label: {
          Label("Open Dashboard Policies", systemImage: "arrow.up.right.square")
        }
        .keyboardShortcut(.defaultAction)
        .padding(.bottom, HarnessMonitorTheme.spacingLG)
      }
    }
    .task {
      openPoliciesRoute()
    }
  }

  private func openPoliciesRoute() {
    guard !hasRequestedOpen else {
      return
    }
    hasRequestedOpen = true
    openDashboardRoute(.policyCanvas)
  }
}
