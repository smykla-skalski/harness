import Foundation
import SwiftUI

extension PolicyCanvasViewModel {
  /// Debounce window for autosave. 1.5s coalesces all mutations from a single
  /// drag gesture or typing burst into one save call; shorter windows flood
  /// the daemon with mid-stroke saves that the user will overwrite with the
  /// next keystroke, and longer windows lose recent edits if the app dies.
  static let autosaveDebounceMilliseconds: UInt64 = 1500

  /// Cancel any in-flight autosave Task and clear the slot. Callers that
  /// begin a foreground save (manual Save button) MUST call this on entry —
  /// otherwise the foreground save and the trailing autosave race for the
  /// same `backingDocument.revision`, and whichever finishes second
  /// overwrites the other's reload result.
  func cancelAutosave() {
    autosaveTask?.cancel()
    autosaveTask = nil
  }

  /// Suppress the next autosave trigger. Used by `restoreState(_:)` so the
  /// `documentDirty = true` write it performs on the rollback path does not
  /// kick the same daemon save that just rejected. Wave 2D's snapshot/restore
  /// contract keeps the local copy dirty so the user can manually retry;
  /// without suppression the autosave loop would hammer the daemon with the
  /// same rejected payload every debounce window.
  func suppressAutosaveOnce() {
    autosaveSuppressed = true
  }

  /// Schedule a debounced autosave. Each call cancels the previous in-flight
  /// task, so N rapid calls (one per documentDirty flip) coalesce into one
  /// actual save. The trailing call wins. The `performSave` closure runs the
  /// same daemon round-trip + snapshot/restore + reload flow as the manual
  /// Save button; the view-model knows nothing about the daemon directly.
  ///
  /// Suppression cases (all return without scheduling):
  /// - `autosaveSuppressed`: a rollback just fired. Reset the flag and let
  ///   the next dirty flip schedule afresh.
  /// - `backingDocument == nil`: the canvas is showing the sample document
  ///   (or initial-load has not completed). There is nothing on the daemon
  ///   to update; the user must save manually first.
  /// - `isSavingDraft`: a foreground save is in flight. The autosave task
  ///   we'd schedule here would race the foreground reload; the foreground
  ///   save already covers the same dirty payload.
  ///
  /// On wake (after the debounce sleep) the task re-checks `documentDirty`
  /// — if the user manually saved during the window, the flag is false and
  /// we exit without firing a redundant save.
  func scheduleAutosave(performSave: @escaping @MainActor () async -> Void) {
    if autosaveSuppressed {
      autosaveSuppressed = false
      return
    }
    guard backingDocument != nil else {
      return
    }
    guard !isSavingDraft else {
      return
    }
    let interval = Self.autosaveDebounceMilliseconds
    cancelAutosave()
    autosaveTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(Int(interval)))
      guard let self else { return }
      guard !Task.isCancelled else { return }
      // Re-check the suppression flag in case a reject landed during the
      // sleep window. The flag is one-shot: consume it here just like the
      // entry check above.
      if self.autosaveSuppressed {
        self.autosaveSuppressed = false
        return
      }
      guard self.documentDirty else { return }
      guard self.backingDocument != nil else { return }
      guard !self.isSavingDraft else { return }
      self.lastAutosaveOutcome = .pending
      await performSave()
    }
  }

  /// Mark the most recent autosave attempt successful. Called from the
  /// host view after the daemon round-trip returns `true`. Surface side
  /// effect: tells the chrome "Autosave succeeded {time}".
  func markAutosaveSucceeded(at date: Date = Date()) {
    lastAutosaveOutcome = .succeeded(at: date)
  }

  /// Mark the most recent autosave attempt failed. Called from the host
  /// view after the daemon round-trip returns `false` (rejected). The
  /// host MUST also call `suppressAutosaveOnce()` before calling
  /// `restoreState(_:)` to break the retry loop — without that, the
  /// rollback's dirty-write would re-trigger autosave next mutation.
  func markAutosaveFailed(at date: Date = Date()) {
    lastAutosaveOutcome = .failed(at: date)
  }
}
