#if DEBUG
import Foundation

/// Hot-reload support for the Policy Canvas Lab (Debug builds only).
///
/// InjectionIII / InjectionNext recompiles an edited source file into a dylib
/// and rebinds its symbols in the running process. The lab and the
/// `HarnessMonitorPolicyCanvas` framework link `-Xlinker -interposable` so the
/// statically dispatched layout and routing code is rebindable (see
/// `BuildSettings.policyCanvasHotReloadLinkOverrides`). After a successful swap
/// the injector posts `INJECTION_BUNDLE_NOTIFICATION`; the lab observes it and
/// forces a reflow so the freshly injected code recomputes. Node positions are
/// cached on the view model and edge routes are gated by a generation counter,
/// so a plain redraw keeps showing the pre-edit graph - the forced reflow is
/// what makes an algorithm change visible.
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
}
#endif
