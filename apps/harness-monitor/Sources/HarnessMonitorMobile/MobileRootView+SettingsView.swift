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
            Label("Scan Mac QR", systemImage: "qrcode.viewfinder")
          }
          if store.syncStatus.opensAppSettingsForRecovery {
            SyncStatusRow(status: store.syncStatus)
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
              Spacer(minLength: 8)
              Button(role: .destructive) {
                pendingUnpairCredential = credential
              } label: {
                Label("Unpair", systemImage: "xmark.circle")
              }
              .buttonStyle(.borderless)
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
                Text(category.subtitle)
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
          }
          Button {
            Task {
              await store.requestNotificationAuthorization()
            }
          } label: {
            Label("Enable Notifications", systemImage: "bell.badge")
          }
        }
        Section("Privacy") {
          LabeledContent("CloudKit", value: "Private database")
          LabeledContent("Payloads", value: "End-to-end encrypted")
          LabeledContent("Retention", value: "7 days")
          LabeledContent("Stations", value: "\(store.mirroredPrivacyStationCount)")
          if let inventory = store.lastPrivacyInventory {
            LabeledContent("Last report", value: "\(inventory.totalRecordCount) records")
            LabeledContent("Encrypted", value: "\(inventory.encryptedRecordCount)")
            LabeledContent("Tombstones", value: "\(inventory.tombstoneRecordCount)")
            LabeledContent("Expired", value: "\(inventory.expiredRecordCount)")
            LabeledContent("Encrypted bytes", value: "\(inventory.encryptedPayloadByteCount)")
          }
          Toggle(
            "Demo mode",
            isOn: Binding(
              get: { store.demoModeEnabled },
              set: { store.setDemoMode($0) }
            )
          )
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
          Button(role: .destructive) {
            deleteMirrorConfirmationPresented = true
          } label: {
            Label("Delete CloudKit mirrors", systemImage: "trash")
          }
          .disabled(!store.canManageMirroredPrivacyRecords)
        }
      }
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
        Text(verbatim:
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
}

struct MobileMirrorExportFile: Identifiable {
  let url: URL

  var id: String {
    url.absoluteString
  }
}
