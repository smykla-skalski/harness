import HarnessMonitorMirrorStore
import SwiftUI
import WatchKit

struct WatchRemoteDaemonPairingView: View {
  @Environment(MirrorStore.self)
  private var store
  @Environment(\.dismiss)
  private var dismiss
  @State private var pairingLink = ""
  @State private var isPairing = false
  @State private var didAttemptPairing = false

  var body: some View {
    Form {
      Section("Remote Daemon") {
        TextField("Pairing Link", text: $pairingLink)
          .privacySensitive()
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .lineLimit(1)
          .frame(height: 44)
        if isPairing {
          ProgressView("Pairing")
        } else {
          Button(action: pair) {
            Label("Pair", systemImage: "link")
          }
          .disabled(pairingLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
      if didAttemptPairing, !isPairing {
        Section {
          Text(store.presentedSyncStatus.subtitle)
            .foregroundStyle(.secondary)
        }
      }
    }
    .navigationTitle("Remote Pairing")
  }

  private func pair() {
    let payload = pairingLink
    guard !payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return
    }
    isPairing = true
    didAttemptPairing = true
    pairingLink = ""
    Task { @MainActor in
      let paired = await store.pairDirectWatchDaemon(
        payload: payload,
        deviceName: WKInterfaceDevice.current().name
      )
      isPairing = false
      if paired {
        dismiss()
      }
    }
  }
}

#Preview {
  NavigationStack {
    WatchRemoteDaemonPairingView()
      .environment(MirrorStore(demoModeEnabled: false, profile: .watch))
  }
}
