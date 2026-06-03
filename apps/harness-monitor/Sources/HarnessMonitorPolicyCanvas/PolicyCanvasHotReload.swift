#if DEBUG
import AppKit
import Foundation
import HarnessMonitorKit

/// Hot-reload support for the Policy Canvas Lab (Debug builds only).
///
/// InjectionIII / InjectionNext recompiles an edited source file into a dylib
/// and rebinds its symbols in the running process. The lab and the
/// `HarnessMonitorPolicyCanvas` framework link `-Xlinker -interposable` so the
/// statically dispatched layout and routing code is rebindable (see
/// `BuildSettings.policyCanvasHotReloadLinkOverrides`). After a successful swap
/// the injector posts `INJECTION_BUNDLE_NOTIFICATION`; the lab observes it,
/// recomputes the displayed document so the freshly injected code takes effect,
/// and plays a short chime. Node positions are cached on the view model and edge
/// routes are gated by a generation counter, so a plain redraw keeps showing the
/// pre-edit graph - the forced document reload is what makes an algorithm change
/// visible, and the chime tells you to glance at the window.
///
/// Workflow and prerequisites: `docs/agent-guides/policy-canvas-hot-reload.md`.
public enum PolicyCanvasHotReload {
  /// Name the injector posts after loading a recompiled bundle. Matches the
  /// constant used by InjectionIII, InjectionNext, and the `Inject` package.
  public static let injectionNotification = Notification.Name("INJECTION_BUNDLE_NOTIFICATION")

  /// Load the injection bundle once at launch. The search order mirrors the
  /// `Inject` package: an app-embedded copy first (covers runs that copy the
  /// bundle in a build phase), then the InjectionIII and InjectionNext app
  /// bundles under `/Applications`. Safe to call when nothing is installed - it
  /// logs a hint and returns without effect.
  public static func loadInjectionBundle() {
    if let embedded = Bundle.main.path(forResource: "macOSInjection", ofType: "bundle"),
      Bundle(path: embedded)?.load() == true {
      return
    }
    for app in ["InjectionIII", "InjectionNext"] {
      let path = "/Applications/\(app).app/Contents/Resources/macOSInjection.bundle"
      if Bundle(path: path)?.load() == true {
        return
      }
    }
    print(
      "Policy Canvas Lab hot reload: install InjectionIII or InjectionNext in "
        + "/Applications to enable live editing"
    )
  }

  /// Name of the macOS system sound played after a successful injection. "Glass"
  /// is a gentle, distinctive chime; swap in any name from
  /// `/System/Library/Sounds` to taste.
  public static let reloadChimeSoundName = "Glass"

  /// Resolve the configured system sound. Split out from `playReloadChime` so a
  /// test can confirm the name maps to a real sound without producing audio.
  @MainActor
  static func reloadChimeSound() -> NSSound? {
    NSSound(named: NSSound.Name(reloadChimeSoundName))
  }

  /// Play a short chime so you know to glance at the lab window when an
  /// injection lands. Best effort - silent if the named sound is missing.
  @MainActor
  public static func playReloadChime() {
    reloadChimeSound()?.play()
  }
}

@MainActor
extension PolicyCanvasViewModel {
  /// Re-render the lab after an injection so the freshly compiled layout and
  /// routing algorithms take effect on the currently displayed document.
  ///
  /// Uses a forced document reload, not `reflowLayout`. A reload re-runs
  /// `policyCanvasCleanInitialLayout` with the current algorithm selection (the
  /// injected code), recomputes routes, and leaves `documentDirty` false.
  /// `reflowLayout` would mark the document dirty, and then
  /// `shouldApplyExternalDocument`'s dirty guard blocks every later policy
  /// switch from updating the canvas.
  func applyHotReloadedAlgorithms(
    document: TaskBoardPolicyPipelineDocument?,
    simulation: TaskBoardPolicyPipelineSimulationResult?,
    audit: TaskBoardPolicyPipelineAuditSummary?
  ) {
    applyDocument(
      document: document,
      simulation: simulation,
      audit: audit,
      forceDocumentReload: true
    )
  }
}
#endif
