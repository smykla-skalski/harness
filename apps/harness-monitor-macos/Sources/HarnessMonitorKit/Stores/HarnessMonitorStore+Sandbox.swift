import Foundation

extension HarnessMonitorStore {
  /// Signals the main window to present the Open Folder file importer.
  ///
  /// The actual `fileImporter` lives in `HarnessMonitorApp` so it can bind to
  /// the app scene's `@State`. Incrementing `openFolderRequest` lets any view
  /// (including the Preferences pane) trigger the panel without needing a
  /// direct binding to the app-level state.
  public func requestOpenFolder() {
    openFolderRequest += 1
  }

  /// Handles a `fileImporter` result by bookmarking the selected folder.
  ///
  /// Call this from any site that presents its own `.fileImporter`, including
  /// the main window handler in `HarnessMonitorApp` and sheets that need to
  /// present their own file picker over a modal context.
  public func handleImportedFolder(_ result: Result<[URL], any Error>) async {
    switch result {
    case .success(let urls):
      guard let url = urls.first else { return }
      guard let store = bookmarkStore else {
        presentFailureFeedback("Bookmark store unavailable: app group container missing")
        return
      }
      do {
        // The `.fileImporter` URL is already scoped for this process, so the
        // outer `withSecurityScopeAsync` is a no-op on this path; we keep it
        // for symmetry with resolve-time reuse flows that do require the
        // start/stop dance and to avoid two different call shapes.
        try await url.withSecurityScopeAsync { scopedURL in
          _ = try await store.add(url: scopedURL, kind: .projectRoot)
        }
      } catch {
        presentFailureFeedback("Could not bookmark folder: \(error.localizedDescription)")
      }
    case .failure(let error):
      presentFailureFeedback("Could not open folder: \(error.localizedDescription)")
    }
  }
}
