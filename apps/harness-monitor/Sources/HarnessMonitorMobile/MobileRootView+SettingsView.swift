import HarnessMonitorCloudMirror
import HarnessMonitorCore
import HarnessMonitorCrypto
import SwiftUI
import UIKit

struct SettingsView: View {
  @Environment(MobileMonitorStore.self)
  private var store
  @State private var scannerPresented = false
  @State private var deleteMirrorConfirmationPresented = false
  @State private var pendingUnpairCredential: MobilePairedStationCredential?
  @State private var mirrorExportFile: MobileMirrorExportFile?

  var body: some View {
    @Bindable var store = store
    NavigationStack {
      List {
        Section("Pairing") {
          Button {
            scannerPresented = true
          } label: {
            HStack {
              HarnessCompactIconText(title: "Scan Mac QR", systemImage: "qrcode.viewfinder")
              Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
          }
          .foregroundStyle(.blue)
          .harnessBalancedListSeparator()
          Toggle(
            "Demo mode",
            isOn: Binding(
              get: { store.demoModeEnabled },
              set: { store.setDemoMode($0) }
            )
          )
          .harnessBalancedListSeparator()
          if store.syncStatus.opensAppSettingsForRecovery {
            SyncStatusRow(status: store.syncStatus)
              .harnessBalancedListSeparator()
          }
          ForEach(store.pairedCredentials) { credential in
            HStack(alignment: .top, spacing: 12) {
              VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                  Text(credential.stationName)
                  if credential.defaultStation {
                    Text("Default")
                      .font(.caption2.weight(.semibold))
                      .padding(.horizontal, 6)
                      .padding(.vertical, 2)
                      .background(.blue.opacity(0.14), in: Capsule())
                      .foregroundStyle(.blue)
                  }
                }
                Text(credential.stationPublicKeyFingerprint)
                  .font(.caption.monospaced())
                  .foregroundStyle(.secondary)
                Text(credential.pairedAt.formatted(date: .abbreviated, time: .shortened))
                  .font(.caption2)
                  .foregroundStyle(.secondary)
              }
              .accessibilityElement(children: .combine)
              Spacer(minLength: 8)
              Button(role: .destructive) {
                pendingUnpairCredential = credential
              } label: {
                Label("Unpair", systemImage: "xmark.circle")
              }
              .buttonStyle(.borderless)
            }
            .harnessBalancedListSeparator()
          }
        }
        Section("Trusted Devices") {
          if trustedDevices.isEmpty {
            Label("No trusted devices mirrored", systemImage: "key.slash")
              .foregroundStyle(.secondary)
              .harnessBalancedListSeparator()
          } else {
            ForEach(trustedDevices) { device in
              TrustedDeviceRow(device: device)
            }
          }
        }
        Section("Notifications") {
          ForEach(MobileNotificationCategory.allCases) { category in
            Toggle(
              isOn: Binding(
                get: { store.notificationSettings.isEnabled(category) },
                set: { store.setNotificationCategory(category, enabled: $0) }
              )
            ) {
              VStack(alignment: .leading, spacing: 2) {
                Text(category.title)
                Text(category.settingsSubtitle)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
                  .minimumScaleFactor(0.82)
              }
            }
            .harnessBalancedListSeparator()
          }
          Button {
            Task {
              await store.requestNotificationAuthorization()
            }
          } label: {
            Label("Enable Notifications", systemImage: "bell.badge")
          }
          .harnessActionButtonStyle(prominent: true)
          .harnessBalancedListSeparator()
        }
        Section("Privacy") {
          LabeledContent("CloudKit", value: "Private database")
            .harnessBalancedListSeparator()
          LabeledContent("Payloads", value: "E2E encrypted")
            .harnessBalancedListSeparator()
          LabeledContent("Retention", value: retentionDescription)
            .harnessBalancedListSeparator()
          LabeledContent("Stations", value: "\(store.mirroredPrivacyStationCount)")
            .harnessBalancedListSeparator()
          if let inventory = store.lastPrivacyInventory {
            LabeledContent("Last report", value: "\(inventory.totalRecordCount) records")
              .harnessBalancedListSeparator()
            LabeledContent("Encrypted", value: "\(inventory.encryptedRecordCount)")
              .harnessBalancedListSeparator()
            LabeledContent("Tombstones", value: "\(inventory.tombstoneRecordCount)")
              .harnessBalancedListSeparator()
            LabeledContent("Expired", value: "\(inventory.expiredRecordCount)")
              .harnessBalancedListSeparator()
            LabeledContent("Encrypted bytes", value: "\(inventory.encryptedPayloadByteCount)")
              .harnessBalancedListSeparator()
          }
        }
        Section("Mirror Management") {
          LabeledContent("Scope", value: "Private CloudKit")
            .harnessBalancedListSeparator()
          LabeledContent("Safety", value: "Mac can rebuild")
            .harnessBalancedListSeparator()
          Button {
            Task {
              guard let url = await store.exportMirroredRecords() else {
                return
              }
              mirrorExportFile = MobileMirrorExportFile(url: url)
            }
          } label: {
            Label("Export all mirrored records", systemImage: "square.and.arrow.up")
          }
          .disabled(!store.canManageMirroredPrivacyRecords)
          .harnessBalancedListSeparator()
          Button(role: .destructive) {
            deleteMirrorConfirmationPresented = true
          } label: {
            Label("Delete CloudKit mirrors", systemImage: "trash")
          }
          .disabled(!store.canManageMirroredPrivacyRecords)
          .harnessBalancedListSeparator()
        }
      }
      .harnessMonitorListChrome()
      .navigationTitle("Settings")
      .sheet(isPresented: $scannerPresented) {
        MobilePairingScannerView { url in
          scannerPresented = false
          Task {
            await store.handleOpenURL(url, deviceName: UIDevice.current.name)
          }
        }
      }
      .sheet(item: $mirrorExportFile) { exportFile in
        NavigationStack {
          ShareLink(item: exportFile.url) {
            Label("Share mirror export", systemImage: "square.and.arrow.up")
          }
          .navigationTitle("Mirror Export")
          .toolbar {
            Button("Done") {
              mirrorExportFile = nil
            }
          }
        }
        .presentationDetents([.medium])
      }
      .confirmationDialog(
        "Delete CloudKit mirrors?",
        isPresented: $deleteMirrorConfirmationPresented,
        titleVisibility: .visible
      ) {
        Button("Delete Mirrors", role: .destructive) {
          Task {
            await store.deleteCloudKitMirror()
          }
        }
      } message: {
        let count = store.mirroredPrivacyStationCount
        let plural = count == 1 ? "" : "s"
        Text(
          verbatim:
            "Deletes encrypted mirror records for \(count) station\(plural) "
            + "from your private CloudKit database. "
            + "Local pairing can rebuild fresh mirrors from the Mac."
        )
      }
      .confirmationDialog(
        "Unpair Mac?",
        isPresented: Binding(
          get: { pendingUnpairCredential != nil },
          set: { if !$0 { pendingUnpairCredential = nil } }
        ),
        titleVisibility: .visible,
        presenting: pendingUnpairCredential
      ) { credential in
        Button("Unpair \(credential.stationName)", role: .destructive) {
          Task {
            await store.unpair(stationID: credential.stationID)
            pendingUnpairCredential = nil
          }
        }
      } message: { _ in
        Text(
          "This removes the local pairing credential and syncs the updated trusted-device set to Apple Watch."
        )
      }
    }
  }

  private var retentionDescription: String {
    let days = Int((MobileCloudMirrorSchema.sevenDayRetention / 86_400).rounded())
    return days == 1 ? "1 day" : "\(days) days"
  }

  private var trustedDevices: [MobileDeviceDescriptor] {
    store.snapshot.trustedDevices.sorted {
      if $0.lastCommandAt != $1.lastCommandAt {
        return ($0.lastCommandAt ?? .distantPast) > ($1.lastCommandAt ?? .distantPast)
      }
      if $0.pairedAt != $1.pairedAt {
        return $0.pairedAt > $1.pairedAt
      }
      return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
    }
  }
}

extension MobileNotificationCategory {
  fileprivate var settingsSubtitle: String {
    switch self {
    case .needsYou:
      "Reviews and blocked agents."
    case .criticalDecision:
      "High-priority permissions."
    case .commandStatus:
      "Accepted, running, completed."
    case .commandFailure:
      "Failed or expired receipts."
    case .stationHealth:
      "Stale or offline Mac relays."
    }
  }
}

struct MobileMirrorExportFile: Identifiable {
  let url: URL

  var id: String {
    url.absoluteString
  }
}

struct TrustedDeviceRow: View {
  let device: MobileDeviceDescriptor

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline) {
        HarnessCompactIconText(title: device.displayName, systemImage: iconName)
          .font(.headline)
          .lineLimit(1)
        Spacer(minLength: 8)
        Text(lastCommandText)
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.secondary)
      }
      Text(device.publicKeyFingerprint)
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
      Text("Paired \(device.pairedAt.formatted(date: .abbreviated, time: .shortened))")
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
    .padding(.vertical, 3)
    .harnessBalancedListSeparator()
    .accessibilityElement(children: .combine)
  }

  private var iconName: String {
    device.id.localizedCaseInsensitiveContains("watch") ? "applewatch" : "iphone"
  }

  private var lastCommandText: String {
    guard let lastCommandAt = device.lastCommandAt else {
      return "No commands"
    }
    return lastCommandAt.formatted(.relative(presentation: .named))
  }
}
