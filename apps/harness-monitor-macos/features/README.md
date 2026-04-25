# Optional features

The Harness Monitor macOS app supports opt-in feature flags that gate optional
SPM packages, source files, and UI surfaces out of the compiled binary unless an
environment variable is set at project-generation time.

## Convention

- One env var per feature: `HARNESS_FEATURE_<NAME>` (uppercase, snake-case).
- Truthy values: `1`, `true`, `yes`, `on` (case-insensitive). Anything else (or
  unset) keeps the feature OFF.
- The env var must be set when running `mise run monitor:macos:generate`. It is
  consumed by `Scripts/generate-project.sh`, which composes a transient
  `apps/harness-monitor-macos/.generated/project.merged.yml` from the canonical
  `project.yml` plus one `features/<name>.yml` fragment per enabled flag.
- The same flag becomes a Swift compilation condition with the same name, so
  source code can use `#if HARNESS_FEATURE_<NAME>` for inline branches.

## Currently supported

| Flag | Effect when ON |
|------|----------------|
| `HARNESS_FEATURE_LOTTIE` | Pulls in `lottie-ios`, compiles `Sources/{HarnessMonitor,HarnessMonitorUIPreviewable}/Features/Lottie/`, exposes the dancing-llama corner animation + Preferences toggle, bundles `DancingLlama.json`. |
| `HARNESS_FEATURE_OTEL` | Pulls in `opentelemetry-swift`, `opentelemetry-swift-core`, and `grpc-swift`; compiles `Sources/HarnessMonitorKit/Features/Otel/` and `Tests/HarnessMonitorKitTests/Features/Otel/`; activates `HarnessMonitorTelemetry` bootstrap, span/metric instrumentation, and shutdown hooks across the app. |

## Tracked project state

`HarnessMonitor.xcodeproj/project.pbxproj` is committed in the **all-features-OFF**
state. Anyone building with a feature flag set must regenerate locally and must
NOT commit the regenerated pbxproj unless every CI policy default agrees with
that state.

To verify drift: `unset HARNESS_FEATURE_*; mise run monitor:macos:generate; git
diff --exit-code apps/harness-monitor-macos/HarnessMonitor.xcodeproj`.

## Adding a new feature

1. Pick `HARNESS_FEATURE_<NAME>`.
2. Create `features/<name>.yml` declaring SPM packages, target deps, source
   directories, and the matching `SWIFT_ACTIVE_COMPILATION_CONDITIONS` entry.
3. Move feature-only source files into
   `Sources/<Target>/Features/<Name>/` and `Sources/<OtherTarget>/Features/<Name>/`.
   Each owning target's base `sources:` glob already excludes `Features/**`, so
   the fragment is the only thing that re-adds them.
4. Add `<NAME>` to the `SUPPORTED_FEATURES` list in
   `Scripts/generate-project.sh`.
5. Inline `#if HARNESS_FEATURE_<NAME>` only at the few base-source call sites
   that reference symbols from the feature directory.
6. Document the flag in the table above.
