# Performance instrumentation rules

## Signpost contract

The perf driver and XCTest perf tests share a signpost contract. Both sides must agree on all three values:

- Subsystem: `"io.harnessmonitor"`
- Category: `"perf"`
- Name: the scenario's raw value (e.g. `"launch-dashboard"`)

If the subsystem or category drifts between the driver (`OSSignposter`) and the tests (`XCTOSSignpostMetric`), the metric captures zero data silently. No error, just empty results.

The driver uses `beginAnimationInterval` (not `beginInterval`). The animation variant tells the system to track rendering hitches during the interval. Using plain `beginInterval` would lose hitch/frame data.

## Adding a new perf scenario

When adding a case to `HarnessMonitorPerfScenario`, update all of these:

1. The enum case and `rawValue` in `HarnessMonitorAppConfiguration.swift`
2. `defaultPreviewScenario` and `initialPreferencesSection` on the enum
3. `signpostName` in the private extension in `HarnessMonitorAppSceneSupport.swift` (must return `StaticString` matching the raw value exactly)
4. The scenario's execution branch in `HarnessMonitorPerfDriver.run(scenario:store:openWindow:)`
5. A `testXxxHitchRate()` method in `HarnessMonitorPerfTests.swift`
6. `scenarioWaitDuration` in `HarnessMonitorPerfTests.swift`
7. The `ALL_SCENARIOS` array in `Scripts/run-instruments-audit.sh`
8. The `SWIFTUI_SCENARIOS` or `ALLOCATIONS_SCENARIOS` array in `Scripts/run-instruments-audit.sh`
9. The `preview_scenario_for` and `duration_for` functions in `Scripts/run-instruments-audit.sh`
10. The `templates` dict in the manifest generation Python block in `Scripts/run-instruments-audit.sh`

Missing any of these causes silent failures - the test runs but captures no signpost data, or the xctrace pipeline skips the scenario.

## Perf test environment variables

Perf tests must set `HARNESS_MONITOR_KEEP_ANIMATIONS=1`. Without it, the UI test animation modifier (`HarnessMonitorUITestAnimationModifier`) disables all SwiftUI animations and the app delegate disables AppKit animations when `HARNESS_MONITOR_UI_TESTS=1`. Measuring hitches with animations disabled is meaningless.

Do not set `HARNESS_MONITOR_LAUNCH_MODE` explicitly in perf tests. The scenario's `applyingDefaults(to:)` sets it to `preview` automatically. Setting it manually creates a second source of truth.

## Never run perf tests in the default suite

Perf tests take 8-12 seconds per scenario per iteration (3 iterations default). They steal window focus and are inherently noisy. Do not add them to the default `xcodebuild test` lane. Run them with `-only-testing:HarnessMonitorUITests/HarnessMonitorPerfTests` or as individual methods.

## Isolate instrumentation runs in a temporary worktree

Instrumentation/audit runs must not execute from a dirty shared worktree. They build, stage, launch, and trace app bundles, so parallel edits in the main checkout can make the run measure the wrong source revision or mix unrelated changes into the build.

For every `Scripts/run-instruments-audit.sh` run that is intended to prove a performance fix:

1. Create a temporary worktree from the exact commit or ref under test, preferably under `/tmp`, for example:

   ```bash
   git worktree add /tmp/harness-monitor-audit-<sha>-<date> <sha-or-ref>
   ```

2. Immediately run `mise trust` inside that new worktree before any build or audit command:

   ```bash
   (cd /tmp/harness-monitor-audit-<sha>-<date> && mise trust)
   ```

   This is required so audit logs do not get polluted by mise trust warnings and so the worktree uses the expected repo tool configuration.

3. Run `apps/harness-monitor-macos/Scripts/run-instruments-audit.sh` from inside that worktree. Compare against the baseline path from the main repo only when needed; do not run the audit from the main worktree just to access the baseline.

4. Verify the generated `manifest.json` before trusting the numbers. The embedded commit, dirty flag, workspace fingerprint, host binary hash, and staged host bundle ID must match the worktree/ref being measured.

5. Clean up the temporary worktree when the run is finished and artifacts needed for the report have been copied or recorded:

   ```bash
   git worktree remove /tmp/harness-monitor-audit-<sha>-<date>
   ```

Leaving audit worktrees behind is not acceptable. If cleanup fails because a process still owns files in the worktree, stop the leftover process and rerun `git worktree remove`.

## xctrace scripts

The Python scripts under `Scripts/` parse Instruments XML exports. They must stay compatible with the xctrace export format, which uses ref-based deduplication for elements. The `dereference` function in `extract-instruments-metrics.py` handles transitive refs (ref -> ref -> element).

When modifying the extractor or comparator, run the parser regression tests:

```
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover \
  -s apps/harness-monitor-macos/Scripts/tests -p 'test_*.py'
```

Test fixtures in `Scripts/tests/fixtures/` are minimal XML samples. Update them when adding new schema parsers.
