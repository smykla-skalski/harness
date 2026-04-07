---
description: Prevent idle CPU waste from always-on animations, formatter allocation, and gratuitous periodic effects
globs: apps/harness-monitor-macos/Sources/**/*.swift
---

# SwiftUI idle CPU prevention

## Never use .repeatForever() on always-visible views

`.repeatForever()` forces the rendering pipeline to run at 60fps permanently, consuming CPU even when the app is idle. This applies to any animation modifier - scale, opacity, rotation, offset.

Allowed uses of `.repeatForever()`:
- Spinner/loading indicators that are **only visible during transient loading states** (seconds, not minutes)
- Content that the user explicitly started and will explicitly stop

Banned uses:
- Status indicators that are visible during normal idle operation (connection dots, activity pulses)
- Decorative ambient animations (breathing effects, idle hints, attention-seeking loops)
- Any view that remains on screen indefinitely

For state-change feedback on always-visible elements, use `phaseAnimator` with a trigger that fires once per transition:

```swift
// correct - fires once on state change, then idle
@State private var flashTrigger = 0
.onChange(of: isActive) { _, active in
  guard active else { return }
  flashTrigger += 1
}
.phaseAnimator(Phase.allCases, trigger: flashTrigger) { view, phase in
  view.scaleEffect(phase.scale)
} animation: { phase in
  switch phase {
  case .idle: .easeOut(duration: 0.3)
  case .bright: .easeIn(duration: 0.12)
  case .settle: .easeOut(duration: 0.3)
  }
}

// wrong - runs at 60fps forever while connected
.animation(
  .easeInOut(duration: 1.2).repeatForever(autoreverses: true),
  value: isPulsing
)
```

## Never allocate formatters in view body or functions called from body

DateFormatter, NumberFormatter, JSONEncoder, ByteCountFormatter - all are expensive to allocate. Cache as `@MainActor` static lets at file scope or on the type.

```swift
// correct - allocated once
@MainActor private let timestampFormatter: DateFormatter = {
  let formatter = DateFormatter()
  formatter.dateFormat = "d MMM HH:mm:ss"
  return formatter
}()

// wrong - allocated every render
func formatTimestamp(_ date: Date) -> String {
  let formatter = DateFormatter()
  formatter.dateFormat = "d MMM HH:mm:ss"
  return formatter.string(from: date)
}
```

If the formatter needs per-call configuration (timezone, calendar), reuse the cached instance and set only the varying properties. Property assignment is orders of magnitude cheaper than allocation.

## No gratuitous periodic animations

`while !Task.isCancelled { sleep; withAnimation { ... } }` loops that run idle hint animations, attention-seeking morphs, or decorative effects burn CPU for no user benefit. Every `withAnimation` triggers a view tree diff.

Acceptable periodic patterns:
- Status ticker rotating messages every 4+ seconds (one state change, minimal cost)
- Connection probe pinging health every 10+ seconds (network I/O, not animation)

Unacceptable periodic patterns:
- Multi-step spring animation sequences on timers (multiple withAnimation + Task.sleep per cycle)
- Idle hint animations that morph between states to attract attention
- Any animation cycle that touches 3+ @State properties

## Don't stack animations on the same view

One animation communicating a state is enough. Two competing animations on the same view (e.g., spinner rotation + pulse opacity/scale) double the rendering cost for no perceptual benefit.

```swift
// correct - spinner alone communicates loading
HStack {
  HarnessMonitorSpinner(size: 14)
  Text(title)
}

// wrong - spinner + redundant pulse animation
HStack {
  HarnessMonitorSpinner(size: 14)
  Text(title)
}
.opacity(animates ? 1 : 0.62)
.scaleEffect(animates ? 1 : 0.97)
.animation(.easeInOut(duration: 1.1).repeatForever(), value: animates)
```
