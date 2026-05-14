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
  /// - `lastAutosaveOutcome == .disabled`: the failure ceiling has fired. The
  ///   chrome shows the sticky affordance; only a successful manual save
  ///   reactivates the scheduler.
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
    guard shouldScheduleAutosave() else {
      return
    }
    let interval = Self.autosaveDebounceMilliseconds
    cancelAutosave()
    autosaveTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(Int(interval)))
      guard let self else { return }
      guard !Task.isCancelled else { return }
      guard self.shouldRunDebouncedAutosave() else { return }
      self.lastAutosaveOutcome = .pending
      await performSave()
    }
  }

  /// Pre-task entry guard: returns true when the scheduler may spawn a new
  /// debounce Task. Consumes the one-shot `autosaveSuppressed` flag on a
  /// rollback-armed call.
  ///
  /// Split out of `scheduleAutosave` so the call site stays under the
  /// cyclomatic-complexity ceiling; behavior is identical to the inline
  /// gate it replaces.
  private func shouldScheduleAutosave() -> Bool {
    if case .disabled = lastAutosaveOutcome {
      return false
    }
    if autosaveSuppressed {
      autosaveSuppressed = false
      return false
    }
    guard backingDocument != nil else {
      return false
    }
    guard !isSavingDraft else {
      return false
    }
    return true
  }

  /// Post-sleep wake guard: returns true when the debounce Task should
  /// actually run the supplied `performSave` closure. Re-checks every
  /// suppression case in case the world changed during the 1.5s sleep
  /// (user manually saved, a reject landed and armed suppression, or the
  /// outcome flipped to `.disabled`).
  private func shouldRunDebouncedAutosave() -> Bool {
    if autosaveSuppressed {
      autosaveSuppressed = false
      return false
    }
    if case .disabled = lastAutosaveOutcome {
      return false
    }
    guard documentDirty else { return false }
    guard backingDocument != nil else { return false }
    guard !isSavingDraft else { return false }
    return true
  }

  /// Mark the most recent autosave attempt successful. Clears the consecutive
  /// failure counter — a successful save proves the daemon is healthy again,
  /// so a future hiccup gets a fresh three-strike window before the ceiling
  /// fires. Also drops any in-flight recovery buffer; the prior reject's
  /// stashed edits are no longer relevant once a save lands clean.
  func markAutosaveSucceeded(at date: Date = Date()) {
    consecutiveAutosaveFailures = 0
    lastAutosaveOutcome = .succeeded(at: date)
    clearRecoveryBuffer()
  }

  /// Mark the most recent autosave attempt failed. Increments the consecutive
  /// failure counter; if it crosses `autosaveFailureCeiling`, flip the
  /// outcome to `.disabled(reason:)` and stop scheduling new autosaves. The
  /// host MUST also call `suppressAutosaveOnce()` before calling
  /// `restoreState(_:)` to break the retry loop — without that, the
  /// rollback's dirty-write would re-trigger autosave next mutation.
  func markAutosaveFailed(at date: Date = Date()) {
    consecutiveAutosaveFailures += 1
    if consecutiveAutosaveFailures >= Self.autosaveFailureCeiling {
      lastAutosaveOutcome = .disabled(reason: Self.autosaveDisabledReason)
      cancelAutosave()
    } else {
      lastAutosaveOutcome = .failed(at: date)
    }
  }

  /// Sticky affordance copy when autosave self-disables after the ceiling.
  /// Stored as a constant so the chrome and the disabled-state assertion in
  /// tests stay in lock-step.
  static let autosaveDisabledReason = "Autosave paused - save manually to retry"

  /// Reset the decompensation state. Called from `markManualSaveSucceeded`
  /// (re-arm autosave on the next dirty flip) and exposed so tests can drop
  /// straight into a known-good state without manually flipping internals.
  func clearAutosaveDecompensation() {
    consecutiveAutosaveFailures = 0
    if case .disabled = lastAutosaveOutcome {
      lastAutosaveOutcome = .idle
    }
  }

  /// Called from the host view after a foreground manual save succeeds. Clears
  /// the consecutive-failure counter and exits the `.disabled` state so the
  /// next dirty flip can schedule autosave again. Also drops any in-flight
  /// recovery buffer — the user just saved, the prior reject's stash is
  /// moot.
  func markManualSaveSucceeded() {
    clearAutosaveDecompensation()
    clearRecoveryBuffer()
  }

  /// Synchronous helper the host view calls BEFORE spawning its save Task.
  /// Setting `isSavingDraft = true` inside the Task body leaves a race window
  /// between `cancelAutosave()` and the flag flip during which an autosave
  /// wake could fire and run a second save in parallel; doing it
  /// synchronously closes the window.
  func beginForegroundSave() {
    cancelAutosave()
    isSavingDraft = true
  }

  /// Companion to `beginForegroundSave`. Use in a `defer` after the
  /// foreground save Task completes.
  func endForegroundSave() {
    isSavingDraft = false
  }
}
