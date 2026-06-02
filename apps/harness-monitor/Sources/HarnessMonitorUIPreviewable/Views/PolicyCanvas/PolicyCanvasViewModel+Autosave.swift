import Foundation
import HarnessMonitorKit
import SwiftUI
import HarnessMonitorPolicyCanvasAlgorithms

extension PolicyCanvasViewModel {
  /// Maximum autosave burst window in milliseconds — the value a fresh install
  /// starts with. Isolated edits use the shorter adaptive quiet window below;
  /// active editing bursts coalesce until this ceiling. The Settings > Policies
  /// autosave picker overrides the per-canvas `autosaveDebounceMilliseconds`
  /// instance value (and `Off` leaves the trigger unbound); Cmd+S flushes
  /// immediately regardless of the window.
  static let defaultAutosaveDebounceMilliseconds: UInt64 = 2_000

  static let adaptiveAutosaveQuietWindowMilliseconds: UInt64 = 750

  /// Cancel any in-flight autosave Task and clear the slot. Callers that
  /// begin a foreground save (manual Save button) MUST call this on entry —
  /// otherwise the foreground save and the trailing autosave race for the
  /// same `backingDocument.revision`, and whichever finishes second
  /// overwrites the other's reload result.
  public func cancelAutosave() {
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

  /// Schedule an adaptive autosave. Each call cancels the previous in-flight
  /// task. Isolated edits save after a short quiet window; edits that keep
  /// bumping `documentGeneration` coalesce until the configured ceiling. The
  /// `performSave` closure runs the same daemon round-trip + snapshot/restore
  /// flow as the manual Save button; the view-model knows nothing about the
  /// daemon directly.
  ///
  /// Suppression cases (all return without scheduling):
  /// - `lastAutosaveOutcome == .disabled`: the failure ceiling has fired. The
  ///   chrome shows the sticky affordance; only a successful manual save
  ///   reactivates the scheduler.
  /// - `autosaveSuppressed`: a rollback just fired. Reset the flag and let
  ///   the next dirty flip schedule afresh.
  /// - `backingDocument == nil`: no daemon-backed document has loaded yet.
  ///   The live canvas may still be on its empty startup state, so there is
  ///   nothing on the daemon to update; the user must save manually first.
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
    // The user's edit is queued, but no persistence has started yet. Keep this
    // visually distinct from the active `.saving` round-trip.
    enterSaveActivity(.pending)
    let maximumInterval = autosaveDebounceMilliseconds
    let quietWindow = min(Self.adaptiveAutosaveQuietWindowMilliseconds, maximumInterval)
    let scheduledGeneration = documentGeneration
    cancelAutosave()
    autosaveTask = Task { @MainActor [weak self] in
      await self?.waitForAdaptiveAutosaveWindow(
        quietWindowMilliseconds: quietWindow,
        maximumWindowMilliseconds: maximumInterval,
        scheduledGeneration: scheduledGeneration
      )
      guard let self else { return }
      guard !Task.isCancelled else { return }
      guard self.shouldRunDebouncedAutosave() else { return }
      self.lastAutosaveOutcome = .pending
      await performSave()
    }
  }

  private func waitForAdaptiveAutosaveWindow(
    quietWindowMilliseconds: UInt64,
    maximumWindowMilliseconds: UInt64,
    scheduledGeneration: UInt64
  ) async {
    guard maximumWindowMilliseconds > 0 else { return }
    var observedGeneration = scheduledGeneration
    var elapsedMilliseconds: UInt64 = 0
    while !Task.isCancelled {
      let remainingMilliseconds =
        maximumWindowMilliseconds > elapsedMilliseconds
        ? maximumWindowMilliseconds - elapsedMilliseconds
        : 0
      guard remainingMilliseconds > 0 else { return }
      let sleepMilliseconds = min(quietWindowMilliseconds, remainingMilliseconds)
      try? await Task.sleep(for: .milliseconds(Int(sleepMilliseconds)))
      let nextElapsed = elapsedMilliseconds.addingReportingOverflow(sleepMilliseconds)
      elapsedMilliseconds =
        nextElapsed.overflow ? maximumWindowMilliseconds : nextElapsed.partialValue
      guard !Task.isCancelled else { return }
      let currentGeneration = documentGeneration
      if currentGeneration == observedGeneration
        || elapsedMilliseconds >= maximumWindowMilliseconds
      {
        return
      }
      observedGeneration = currentGeneration
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
    enterSaveActivity(.saving)
  }

  /// Companion to `beginForegroundSave`. Use in a `defer` after the
  /// foreground save Task completes.
  func endForegroundSave() {
    isSavingDraft = false
    // Edits that landed during the foreground save could not schedule autosave
    // while `isSavingDraft` was true (scheduleAutosave bails on the in-flight
    // guard). Now that the flag is clear, re-arm so those edits are persisted;
    // scheduleAutosave still honors the suppression / disabled / no-backing
    // guards, so a rejected-then-rolled-back save does not re-fire.
    if documentDirty {
      autosaveTrigger?()
    }
  }

  /// Adopt a successfully-saved document as the new clean backing WITHOUT
  /// rebuilding the live graph. The on-screen nodes, groups, and edges already
  /// show the saved content, so this only re-points `backingDocument`, advances
  /// the loaded and self-saved revisions (so the daemon's echo of this save is
  /// never mistaken for a remote change), and clears the dirty flags. Unlike
  /// `applyDocument` it does not recenter the viewport or clear the undo stack —
  /// a save is not a reload.
  func markSavedDocument(_ document: TaskBoardPolicyPipelineDocument) {
    backingDocument = document
    markLoadedDocumentRevision(document.revision)
    lastSelfSavedRevision = document.revision
    documentDirty = false
    viewportDirty = false
    setPendingUpdate(nil)
  }

  /// Resolve a successful daemon save. `saveGeneration` is the graph generation
  /// captured with the outbound document; `savedDocument` is what the daemon
  /// persisted and echoed back — crucially at a BUMPED revision (the daemon
  /// increments on every draft save, `policy_graph/store.rs`). The concurrent
  /// edit check compares generations instead of re-exporting the live graph on
  /// the main actor, while adoption takes `savedDocument` so the canvas tracks
  /// the daemon's real revision — otherwise the daemon's own echo at the bumped
  /// revision reads as a remote change and re-raises the banner.
  ///
  /// Clean (live graph still equals what was sent): adopt `savedDocument` as the
  /// new backing and return `false`. Edited mid-round-trip: record the daemon's
  /// revision as our own, leave the canvas dirty, and return `true` so the host
  /// re-arms one follow-up save for the in-flight edits.
  func resolveSuccessfulSave(
    saveGeneration: UInt64,
    savedDocument: TaskBoardPolicyPipelineDocument
  ) -> Bool {
    guard documentGeneration == saveGeneration else {
      // Edited mid-round-trip: a follow-up save is queued, so leave the pill on
      // its in-flight `.saving` state (the re-arm flips it to `.pending`).
      // Flashing "Saved" here would lie about the diverged live graph. Record
      // the daemon's bumped revision so its echo is not read as a remote change.
      lastSelfSavedRevision = savedDocument.revision
      return true
    }
    markSavedDocument(savedDocument)
    flashWorkflowStatusStage(.draft)
    enterSaveActivity(.idle)
    return false
  }

  /// Flash lifetime for the transient `.saved` check before the pill clears.
  /// 1.5s reads as "that landed" without lingering into the next edit.
  static let saveStatusSavedFlashDuration: Duration = .milliseconds(1_500)

  /// Flash lifetime for the `.failed` marker. Longer than the saved flash —
  /// a failure earns a beat more attention — but the durable failure signal
  /// still lives on the reject toast + the autosave ceiling affordance, so the
  /// pill itself does not need to stay sticky.
  static let saveStatusFailedFlashDuration: Duration = .seconds(4)

  /// Enter a non-transient save activity (`.pending` / `.saving`). Cancels any
  /// armed auto-clear so a stale `.saved` / `.failed` flash cannot stomp the
  /// new state back to `.idle` mid-save.
  func enterSaveActivity(_ activity: PolicyCanvasSaveActivity) {
    saveActivityClearTask?.cancel()
    saveActivityClearTask = nil
    saveActivity = activity
  }

  /// Set a transient save activity (`.saved` / `.failed`) and arm an auto-clear
  /// back to `.idle` after `delay`. Mirrors `triggerGroupAcceptanceFlash`:
  /// cancels the prior clear so rapid saves never leave overlapping timers, and
  /// the clear only fires when the same activity is still showing — a newer
  /// save supersedes it.
  func flashSaveActivity(_ activity: PolicyCanvasSaveActivity, clearAfter delay: Duration) {
    saveActivityClearTask?.cancel()
    saveActivity = activity
    saveActivityClearTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled, let self else { return }
      if self.saveActivity == activity {
        self.saveActivity = .idle
      }
    }
  }

  /// Surface a save failure on the corner pill (both manual and autosave). The
  /// detailed recovery flow stays on the reject toast + sticky affordance; this
  /// is only the brief marker.
  func markSaveActivityFailed() {
    flashSaveActivity(.failed, clearAfter: Self.saveStatusFailedFlashDuration)
  }
}
