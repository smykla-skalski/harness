---
description: SwiftUI performance rules for the AI Harness macOS app
globs: apps/harness-macos/Sources/**/*.swift
---

# SwiftUI performance

## No object creation in body path

Never create DateFormatter, JSONEncoder, NumberFormatter, or similar objects inside a view body or any function called from body. Use static lets.

```swift
// correct
private static let prettyEncoder: JSONEncoder = {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
  return encoder
}()

// wrong - allocates per render
func prettyPrint() -> String {
  let encoder = JSONEncoder()  // created every body call
  ...
}
```

## Thread safety for formatters

DateFormatter and RelativeDateTimeFormatter are not thread-safe. Mark them and their calling functions @MainActor (not nonisolated(unsafe)) since view bodies always run on the main actor.

## Animation scoping

Place .animation(_:value:) on the narrowest view that changes, not on parent containers. Always include the value: parameter. Wrap conditionally-shown content in Group {} when applying animation to avoid animating unrelated siblings.
