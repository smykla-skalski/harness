# Policy Canvas Lab hot reload

Edit the layout and routing algorithms and see the change in the already-open
Policy Canvas Lab window, without a rebuild-and-relaunch cycle. This uses
InjectionIII / InjectionNext to recompile the edited file into a dylib and
rebind its symbols in the running process. Debug builds only - none of this
ships in Release.

## What was wired up

Three pieces make the lab injectable, all gated to the `Debug` configuration:

- `BuildSettings.policyCanvasHotReloadCompileOverrides` / `...LinkOverrides` add
  `-Xlinker -interposable` plus `EMIT_FRONTEND_COMMAND_LINES=YES` and turn the
  compilation cache off. The interposable flag is the load-bearing one: the
  layout and routing code is value types and free functions, which dispatch
  statically, so without it the injector cannot rebind them. The flag goes on
  `HarnessMonitorPolicyCanvas` (the algorithms static framework folds into it)
  and on the `HarnessMonitorPolicyCanvasLab` app. The lab also sets
  `ENABLE_HARDENED_RUNTIME=NO` so it can `dlopen` the recompiled bundle; it
  declares no entitlements file, so it is not sandboxed and needs no exception.
- `HarnessMonitorPolicyCanvasLabApp.init()` loads the injection bundle
  (`PolicyCanvasHotReload.loadInjectionBundle()`).
- `PolicyCanvasViewportSurface` observes the injector's
  `INJECTION_BUNDLE_NOTIFICATION`, recomputes the displayed document, and plays
  a short chime. This last step matters: node positions are cached on the view
  model and edge routes are gated by a generation counter, so a redraw alone
  keeps showing the pre-edit graph. The forced document reload re-runs the
  freshly injected layout and routing code, and the chime tells you to glance at
  the window.

## Prerequisites

Install InjectionIII or InjectionNext from the GitHub releases (not the Mac App
Store build - its bundle lives inside a sandbox container at a different path).
Drop it in `/Applications` and launch it. In its menu, point Open Project at
this repo's `apps/harness-monitor` directory so it watches the source tree.

## Workflow

```bash
mise run monitor:policy-lab:hot
```

That regenerates the project (so the Debug hot-reload settings are present) and
opens the workspace. Then:

1. In Xcode, select the `HarnessMonitorPolicyCanvasLab` scheme and Run (Cmd+R).
2. Edit a file under `Sources/HarnessMonitorPolicyCanvasAlgorithms/Algorithms/`
   (for example `PolicyCanvasVisibilityRouter.swift` for routing or
   `PolicyCanvasAutomaticLayoutEngine.swift` for positioning) or a canvas view,
   and save (Cmd+S).
3. The injector recompiles and rebinds; the lab recomputes, redraws, and plays
   a chime so you know to look.

Run from Xcode rather than the capture script. InjectionIII recovers the
compile flags from the most recent Xcode build log, and an Xcode Run writes that
log to the standard `~/Library/Developer/Xcode/DerivedData` location. The
lane-scoped CLI builds (`xcode-derived-lanes/<lane>`) put the log where the
injector does not look.

## What hot-reloads and what does not

In scope: the layout and routing algorithms in
`HarnessMonitorPolicyCanvasAlgorithms`, plus the canvas views and view model
that compile into `HarnessMonitorPolicyCanvas`. Editing a function body, tuning
a constant, or changing a routing heuristic all take effect on save.

Out of scope: changes that need a real relink - adding or removing a type,
changing a stored property layout, or editing code in other frameworks. Those
still need a normal rebuild.

## Troubleshooting

- The window logs `install InjectionIII or InjectionNext in /Applications` at
  launch: the bundle was not found. Check the app is in `/Applications` and was
  launched at least once.
- Edits compile in the injector console but nothing changes on screen: confirm
  the injector found the build log (its console prints the recompile command).
  If it cannot, do a fresh Run from Xcode so a current log exists.
- Routing edits do not show but layout edits do (or vice versa): the recompute
  observer covers both. If only one updates, the injector likely recompiled one
  file but not the other - save the specific file again.
- A chime sounds but the graph looks unchanged: the recompute ran but the edit
  did not alter this policy's layout. Switch policies or edit a value with a
  visible effect. The chime name is `PolicyCanvasHotReload.reloadChimeSoundName`
  if you want a different sound.
