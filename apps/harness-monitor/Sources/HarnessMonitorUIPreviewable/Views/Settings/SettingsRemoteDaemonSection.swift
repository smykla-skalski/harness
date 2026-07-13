import Foundation
import HarnessMonitorKit
import SwiftUI

struct SettingsRemoteDaemonSection: View {
  private enum PairingMode: String, CaseIterable, Identifiable {
    case link = "Pairing Link"
    case manual = "Manual"

    var id: String { rawValue }
  }

  let profile: RemoteDaemonProfile?
  let actionState: RemoteDaemonActionState
  let pair: @MainActor @Sendable (RemoteDaemonPairingInput, String) -> Void
  let forget: @MainActor @Sendable () -> Void

  @State private var pairingMode = PairingMode.link
  @State private var pairingLink = ""
  @State private var endpoint = ""
  @State private var pairingCode = ""
  @State private var serverPin = ""
  @State private var displayName = Host.current().localizedName ?? "Harness Monitor on macOS"
  @State private var confirmsForget = false

  var body: some View {
    Section {
      if let profile {
        profileRows(profile)
        HarnessMonitorActionButton(
          title: "Forget Remote Daemon",
          tint: .red,
          variant: .bordered,
          accessibilityIdentifier: HarnessMonitorAccessibility.settingsActionButton(
            "Forget Remote Daemon"
          )
        ) {
          confirmsForget = true
        }
        .disabled(actionState.isInFlight)
      } else {
        LabeledContent("Status", value: "Local daemon")
      }
      if let errorMessage = actionState.errorMessage {
        Text(errorMessage)
          .foregroundStyle(.red)
          .textSelection(.enabled)
      }
    } header: {
      Text("Remote Daemon")
        .harnessNativeFormSectionHeader()
    }

    Section {
      Picker("Pair with", selection: $pairingMode) {
        ForEach(PairingMode.allCases) { mode in
          Text(mode.rawValue).tag(mode)
        }
      }
      .pickerStyle(.segmented)
      .harnessNativeFormControl()

      TextField("Client name", text: $displayName)
        .harnessNativeFormControl()
      switch pairingMode {
      case .link:
        SecureField("harness://remote-pair link", text: $pairingLink)
          .harnessNativeFormControl()
      case .manual:
        TextField("HTTPS endpoint", text: $endpoint)
          .harnessNativeFormControl()
        SecureField("One-time pairing code", text: $pairingCode)
          .harnessNativeFormControl()
        TextField("sha256/ SPKI pin", text: $serverPin)
          .harnessNativeFormControl()
      }

      if actionState.isInFlight {
        ProgressView(actionState == .pairing ? "Pairing..." : "Forgetting...")
      } else {
        HarnessMonitorActionButton(
          title: pairingActionTitle,
          tint: nil,
          variant: .prominent,
          accessibilityIdentifier:
            HarnessMonitorAccessibility.settingsActionButton(pairingActionTitle)
        ) {
          pair(pairingInput, displayName)
        }
        .disabled(!canPair)
      }
    } header: {
      Text(profile == nil ? "Pair" : "Replace Profile")
        .harnessNativeFormSectionHeader()
    }
    .confirmationDialog(
      "Forget Remote Daemon?",
      isPresented: $confirmsForget,
      titleVisibility: .visible
    ) {
      Button("Forget Remote Daemon", role: .destructive) {
        guard !actionState.isInFlight else { return }
        forget()
      }
      .disabled(actionState.isInFlight)
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "This revokes this client on the server. "
          + "It removes its bearer token from Keychain and returns to the local daemon mode."
      )
    }
  }

  private var pairingActionTitle: String {
    profile == nil ? "Pair Remote Daemon" : "Replace Remote Daemon"
  }

  @ViewBuilder
  private func profileRows(_ profile: RemoteDaemonProfile) -> some View {
    LabeledContent("Status", value: profile.status.rawValue.capitalized)
    LabeledContent("Endpoint", value: profile.endpoint.absoluteString)
      .textSelection(.enabled)
    LabeledContent("Client", value: profile.displayName)
    LabeledContent("Role", value: profile.role.rawValue.capitalized)
    LabeledContent("Scopes", value: profile.scopes.joined(separator: ", "))
      .textSelection(.enabled)
    LabeledContent("Token", value: profile.tokenHint)
    LabeledContent("Server SPKI") {
      Text(profile.serverSPKISHA256.value)
        .multilineTextAlignment(.trailing)
        .textSelection(.enabled)
    }
  }

  private var pairingInput: RemoteDaemonPairingInput {
    switch pairingMode {
    case .link:
      .deepLink(pairingLink)
    case .manual:
      .manual(endpoint: endpoint, code: pairingCode, serverSPKISHA256: serverPin)
    }
  }

  private var canPair: Bool {
    guard !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return false
    }
    switch pairingMode {
    case .link:
      return !pairingLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    case .manual:
      return [endpoint, pairingCode, serverPin].allSatisfy {
        !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      }
    }
  }
}
