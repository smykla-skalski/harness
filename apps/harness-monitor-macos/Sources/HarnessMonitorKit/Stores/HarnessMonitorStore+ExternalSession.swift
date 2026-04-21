import Foundation

extension HarnessMonitorStore {
  /// Signals the main window to present the Attach External Session file importer.
  public func requestAttachExternalSession() {
    attachSessionRequest += 1
  }

  /// Handles the result of the Attach External Session fileImporter by probing
  /// the selected directory first, then persisting a bookmark only for session
  /// roots we can actually attach.
  public func handleAttachSessionPicker(_ result: Result<[URL], any Error>) async {
    switch result {
    case .success(let urls):
      guard let url = urls.first else { return }
      guard let bookmarks = bookmarkStore else {
        presentFailureFeedback("Bookmark store unavailable: app group container missing")
        return
      }
      let existingIDs = Set(sessions.map(\.sessionId))
      let probe = SessionDiscoveryProbe(existingSessionIDs: existingIDs)
      do {
        let (record, preview) = try await url.withSecurityScopeAsync { scopedURL in
          let preview = try await probe.probe(url: scopedURL)
          let record = try await bookmarks.add(url: scopedURL, kind: .sessionDirectory)
          return (record, preview)
        }
        presentedSheet = .attachExternal(bookmarkId: record.id, preview: preview)
      } catch let failure as SessionDiscoveryProbe.Failure {
        presentFailureFeedback(failureSummary(failure))
      } catch {
        presentFailureFeedback("Could not attach session: \(error.localizedDescription)")
      }
    case .failure(let error):
      presentFailureFeedback("Could not open session folder: \(error.localizedDescription)")
    }
  }
}

private func failureSummary(_ failure: SessionDiscoveryProbe.Failure) -> String {
  switch failure {
  case .notAHarnessSession(let reason):
    "Not a harness session: \(reason)"
  case .unsupportedSchemaVersion(let found, let supported):
    "Unsupported schema version \(found); expected \(supported)."
  case .belongsToAnotherProject(let expected, let found):
    "Origin mismatch: expected \(expected), found \(found)."
  case .alreadyAttached(let sid):
    "Session \(sid) is already attached."
  }
}
