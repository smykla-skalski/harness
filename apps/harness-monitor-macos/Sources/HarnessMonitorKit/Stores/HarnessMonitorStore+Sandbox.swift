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
}
