import Foundation

extension HarnessMonitorStore {
  /// Signals the main window to present the Attach External Session file importer.
  public func requestAttachExternalSession() {
    attachSessionRequest += 1
  }

  /// Handles the result of the Attach External Session fileImporter: bookmarks
  /// the selected directory as `.sessionDirectory`, probes it, and presents the
  /// Attach sheet with the preview (or failure).
  public func handleAttachSessionPicker(_ result: Result<[URL], any Error>) async {
    switch result {
    case .success(let urls):
      guard let url = urls.first else { return }
      guard let bookmarks = bookmarkStore else {
        presentFailureFeedback("Bookmark store unavailable: app group container missing")
        return
      }
      do {
        let record = try await url.withSecurityScopeAsync { scopedURL in
          try await bookmarks.add(url: scopedURL, kind: .sessionDirectory)
        }
        let existingIDs = Set(sessions.map(\.sessionId))
        let probe = SessionDiscoveryProbe(existingSessionIDs: existingIDs)
        do {
          let preview = try await url.withSecurityScopeAsync { scopedURL in
            try await probe.probe(url: scopedURL)
          }
          presentedSheet = .attachExternal(bookmarkId: record.id, preview: preview)
        } catch let failure as SessionDiscoveryProbe.Failure {
          presentFailureFeedback(failureSummary(failure))
        }
      } catch {
        presentFailureFeedback("Could not bookmark folder: \(error.localizedDescription)")
      }
    case .failure(let error):
      presentFailureFeedback("Could not open folder: \(error.localizedDescription)")
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
