import HarnessMonitorKit
import SwiftUI

public struct RemoteDaemonPairingConfirmationView: View {
  public let invitation: RemoteDaemonPairingInvitation
  public let onPair: @MainActor @Sendable (String) -> Void
  public let onCancel: @MainActor @Sendable () -> Void

  @State private var displayName = ""

  private static let expirationFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .medium
    f.timeStyle = .short
    return f
  }()

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

      LabeledContent("Code Expires", value: expirationText)
        .foregroundStyle(expirationColor)

      TextField("Client name", text: $displayName)
        .textFieldStyle(.roundedBorder)
        .labelsHidden()
        .accessibilityLabel("Client name")
        .padding(.top, HarnessMonitorTheme.spacingXS)
    }
  }

  @ViewBuilder
  private var actions: some View {
    HStack(spacing: HarnessMonitorTheme.spacingSM) {
      Button("Cancel", role: .cancel) {
        onCancel()
      }
      .keyboardShortcut(.escape)

      Button("Pair Remote Daemon") {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        onPair(name.isEmpty ? "Harness Monitor on macOS" : name)
      }
      .keyboardShortcut(.defaultAction)
      .buttonStyle(.borderedProminent)
    }
    .frame(maxWidth: .infinity, alignment: .trailing)
  }

  private var expirationText: String {
    Self.expirationFormatter.string(from: invitation.expiresAt)
  }

  private var expirationColor: Color {
    invitation.expiresAt < .now.addingTimeInterval(300) ? .orange : .secondary
  }
}
