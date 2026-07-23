import HarnessMonitorKit
import SwiftUI

public struct RemoteDaemonPairingConfirmationView: View {
  public let invitation: RemoteDaemonPairingInvitation
  public let onPair: @MainActor @Sendable (String) -> Void
  public let onCancel: @MainActor @Sendable () -> Void

  @State private var displayName = ""

  public init(
    invitation: RemoteDaemonPairingInvitation,
    onPair: @escaping @MainActor @Sendable (String) -> Void,
    onCancel: @escaping @MainActor @Sendable () -> Void
  ) {
    self.invitation = invitation
    self.onPair = onPair
    self.onCancel = onCancel
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
        .padding(.horizontal, HarnessMonitorTheme.spacingLG)
        .padding(.top, HarnessMonitorTheme.spacingLG)
        .padding(.bottom, HarnessMonitorTheme.spacingMD)

      Divider()

      details
        .padding(.horizontal, HarnessMonitorTheme.spacingLG)
        .padding(.vertical, HarnessMonitorTheme.spacingMD)

      Divider()

      actions
        .padding(.horizontal, HarnessMonitorTheme.spacingLG)
        .padding(.vertical, HarnessMonitorTheme.spacingMD)
    }
    .frame(width: 420)
    .accessibilityIdentifier(HarnessMonitorAccessibility.remotePairSheet)
    .onAppear {
      guard displayName.isEmpty else { return }
      displayName = Host.current().localizedName ?? "Harness Monitor on macOS"
    }
  }

  @ViewBuilder
  private var header: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      Text("Pair with Remote Daemon")
        .font(.headline)
        .accessibilityAddTraits(.isHeader)
      Text(invitation.endpoint.absoluteString)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .lineLimit(1)
        .truncationMode(.middle)
    }
  }

  @ViewBuilder
  private var details: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      LabeledContent("Endpoint", value: invitation.endpoint.absoluteString)
        .textSelection(.enabled)

      LabeledContent("Role", value: invitation.role.rawValue.capitalized)

      LabeledContent("Scopes", value: invitation.scopes.joined(separator: ", "))
        .textSelection(.enabled)

      LabeledContent("Code Expires") {
        Text(expirationText)
          .foregroundStyle(expirationColor)
      }

      TextField("Client name", text: $displayName)
        .harnessNativeFormControl()
        .labelsHidden()
        .accessibilityLabel("Client name")
        .accessibilityIdentifier(HarnessMonitorAccessibility.remotePairSheetClientNameField)
        .padding(.top, HarnessMonitorTheme.spacingXS)
    }
  }

  @ViewBuilder
  private var actions: some View {
    HStack(spacing: HarnessMonitorTheme.spacingSM) {
      Button("Cancel", role: .cancel) {
        onCancel()
      }
      .keyboardShortcut(.cancelAction)
      .accessibilityIdentifier(HarnessMonitorAccessibility.remotePairSheetCancelButton)

      Button("Pair Remote Daemon") {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        onPair(name.isEmpty ? "Harness Monitor on macOS" : name)
      }
      .keyboardShortcut(.defaultAction)
      .harnessActionButtonStyle(variant: .prominent)
      .accessibilityIdentifier(HarnessMonitorAccessibility.remotePairSheetPairButton)
    }
    .frame(maxWidth: .infinity, alignment: .trailing)
  }

  private var expirationText: String {
    invitation.expiresAt.formatted(date: .abbreviated, time: .shortened)
  }

  private var expirationColor: Color {
    invitation.expiresAt < .now.addingTimeInterval(300) ? .orange : .secondary
  }
}
