import Foundation
import HarnessMonitorCloudMirror
import HarnessMonitorCrypto

extension MobileMonitorStore {
  func exportMirroredRecords() async -> URL? {
    let stationIDs = privacyStationIDs()
    guard !stationIDs.isEmpty else {
      syncStatus = .unpaired
      lastPrivacyInventory = nil
      return nil
    }
    do {
      let now = Date()
      let privacyService = privacyServiceProvider()
      let archive = try await privacyService.exportArchive(
        stationIDs: stationIDs,
        directRecordIDs: await directPrivacyMirrorRecordIDs(),
        now: now
      )
      let data = try archive.encodedData()
      let fileURL = mirrorExportFileURL(generatedAt: now)
      try data.write(to: fileURL, options: [.atomic])
      lastPrivacyInventory = archive.inventory
      let recordCount = archive.inventory.totalRecordCount
      let stationCount = stationIDs.count
      syncStatus = .privacy(
        "Exported \(recordCount) encrypted mirror record\(recordCount == 1 ? "" : "s")"
          + " for \(stationCount) station\(stationCount == 1 ? "" : "s")."
      )
      return fileURL
    } catch {
      syncStatus = mobileMonitorSyncStatus(for: error)
      return nil
    }
  }

  func deleteCloudKitMirror() async {
    let stationIDs = privacyStationIDs()
    guard !stationIDs.isEmpty else {
      syncStatus = .unpaired
      lastPrivacyInventory = nil
      return
    }
    do {
      let privacyService = privacyServiceProvider()
      let deletionReport = try await privacyService.deleteRecordReport(
        stationIDs: stationIDs,
        directRecordIDs: await directPrivacyMirrorRecordIDs(),
        now: .now
      )
      lastPrivacyInventory = deletionReport.inventory
      notificationDeliveryHistory.reset()
      snapshot = snapshot.removingStationData(
        for: stationIDs,
        defaultStationID: defaultStationID ?? selectedStationID
      )
      applyPairedStationPlaceholders(pairedCredentials)
      if selectedStationID.isEmpty || snapshot.station(id: selectedStationID) == nil {
        selectedStationID =
          defaultStationID
          ?? snapshot.stations.first(where: \.defaultStation)?.id
          ?? snapshot.stations.first?.id
          ?? ""
      }
      persistSharedSnapshot(snapshot)
      reconcileLiveActivity(snapshot)
      publishWatchPairingTransfer(snapshot: snapshot)
      let deletedCount = deletionReport.deletedRecordCount
      let stationCount = stationIDs.count
      syncStatus = .privacy(
        "Deleted \(deletedCount) mirrored record\(deletedCount == 1 ? "" : "s")"
          + " for \(stationCount) station\(stationCount == 1 ? "" : "s")."
      )
    } catch {
      syncStatus = mobileMonitorSyncStatus(for: error)
    }
  }

  func mirrorExportFileURL(generatedAt: Date) -> URL {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    let timestamp =
      formatter
      .string(from: generatedAt)
      .replacingOccurrences(of: ":", with: "-")
    return FileManager.default.temporaryDirectory
      .appendingPathComponent("harness-monitor-mirror-\(timestamp)")
      .appendingPathExtension("json")
  }

  func directPrivacyMirrorRecordIDs() async -> [String] {
    var recordIDs: [String] = []
    for credential in pairedCredentials {
      let identity: MobileDeviceIdentity?
      if let loadedIdentity = pairedIdentitiesByID[credential.deviceIdentityID] {
        identity = loadedIdentity
      } else if let identityStore {
        identity = try? await identityStore.load(id: credential.deviceIdentityID)
      } else {
        identity = nil
      }
      guard let identity,
        let fingerprint = try? identity.signingKeyFingerprint()
      else {
        continue
      }
      recordIDs.append(
        MobileCloudMirrorSnapshotWriter.snapshotRecordID(
          stationID: credential.stationID,
          deviceID: identity.id,
          signingKeyFingerprint: fingerprint
        )
      )
    }
    return recordIDs
  }
}
