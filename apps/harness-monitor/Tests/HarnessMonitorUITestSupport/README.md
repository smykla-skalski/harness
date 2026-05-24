# Harness Monitor UI Test Contracts

When a macOS UI test fails because a title, button, or field is "missing", do not invent a new accessibility/query pattern first.
Start by finding the nearest working surface in this app and match its structure.

Current hard-learned example:
- `NewSessionSheetView+CapabilityPicker.swift` duplicates the capability picker from `AgentCapabilityRow.swift`.
- The safe contract is: the row is an accessibility container, but the visible title/probe/buttons remain individually discoverable descendants.
- If the container is over-combined, SwiftUI can hide the visible `Text` nodes from XCUI queries even though the UI still looks correct.

Accessibility identifier contract:
- `HarnessMonitorAccessibility` in `Sources/HarnessMonitorUIPreviewable/Support/` is the production source of truth.
- `HarnessMonitorUITestAccessibility.swift` is only a mirror for UI tests.
- Any new or changed mirrored identifier must be updated in the same commit as `HarnessMonitorUITestAccessibilityRegistryTests.swift`.
- Mirror helpers must preserve the same slugging and path shape as production helpers.

Preferred debugging order for similar failures:
1. Compare the failing surface with the closest passing surface in this repo.
2. Check whether the production accessibility helper and the UI-test mirror still match exactly.
3. Re-run the smallest focused UI test after the contract is aligned.
4. Only then consider changing the test query itself.

Launch reuse contract:
- Only enable `reuseLaunchedApp` for a class when every reused launch stays within the same `mode` plus `additionalEnvironment` signature.
- If a test class needs multiple environment variants, keep them in the smallest number of scenario tests and let the harness relaunch only when that signature actually changes.
- Reused launches own their isolated data home until the cached app is torn down; do not add per-test cleanup that can delete live UI-test storage underneath a running host.

Interaction contract:
- Prefer normal XCTest interaction first (`tap()`, `click()`, keyboard input).
- Fall back to synthetic coordinates only when the element is not hittable, and clamp fallback taps to the containing window's visible frame.
- If a scenario repeatedly opens the same sheet or popover, combine the assertions into one scenario test before adding more one-launch-per-test methods.
