/// Tracks which repository a `.fileImporter` folder pick belongs to.
///
/// `fileImporter` sets its `isPresented` binding back to false *before* it calls
/// `onCompletion`, so a presentation binding derived from the pending repository
/// erases that repository before the handler can read it, and the pick silently
/// does nothing. Keeping presentation and the pending repository in separate
/// stored properties lets dismissal clear only the former.
struct RepositoryFolderImportRequest: Equatable {
  /// Bind this directly to `fileImporter(isPresented:)`.
  var isPresented = false
  private var repository: String?

  mutating func begin(repository: String) {
    self.repository = repository
    isPresented = true
  }

  /// Returns the repository the picker was opened for and clears the request,
  /// so a later completion cannot reuse a stale one.
  mutating func consume() -> String? {
    defer {
      repository = nil
      isPresented = false
    }
    return repository
  }
}
