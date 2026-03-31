---
globs: "**/*.swift"
description: "Visual design rules for macOS and iOS apps: typography, color, spacing, layout, dark mode, motion, icons."
---

# Visual design rules

## Typography

- Use text styles (`.body`, `.headline`, `.caption`), not hardcoded point sizes.
- Maximum 2-3 font weights per screen to establish hierarchy.
- Line length: 50-75 characters for body text (70 optimal). Constrain with `.frame(maxWidth:)`.
- Left-align body text. Never justify on screens.
- Numbers in tables/lists: `.monospacedDigit()` for column alignment.
- ALL CAPS only for short labels (2-3 words) with tracking adjustment.
- Monospace (SF Mono) for: code, terminal output, IDs, hashes, file paths, IP addresses.
- Minimum readable text: 11pt (iOS body=17pt, macOS body=13pt). Never smaller.

### Text style sizes (iOS / macOS)

| Style | iOS | macOS | Use |
|---|---|---|---|
| `.largeTitle` | 34pt | 26pt | Screen headers (one per screen) |
| `.title` | 28pt | 22pt | Section headers |
| `.title2` | 22pt | 17pt | Subsection headers |
| `.title3` | 20pt | 15pt | Card titles |
| `.headline` | 17pt SB | 13pt B | Emphasized body |
| `.body` | 17pt | 13pt | Primary content |
| `.subheadline` | 15pt | 11pt | Supplementary labels |
| `.footnote` | 13pt | 10pt | Timestamps, metadata |
| `.caption` | 12pt | 10pt | Auxiliary info |

## Color

- Use semantic system colors (`.primary`, `.secondary`, `.accent`, `.background`) that auto-adapt to light/dark mode.
- 60-30-10 rule: 60% background, 30% secondary surface, 10% accent color.
- Status colors: red = error/destructive, orange = warning, yellow = caution, green = success, blue = info/link, gray = inactive/disabled.
- One accent color per app for interactive elements (buttons, links, toggles, selection).
- Never use color as the sole indicator of meaning - pair with icon, text, or pattern.

## Dark mode

- Not just color inversion. Elevated surfaces get lighter (depth reversal).
- No pure black (#000000) for macOS backgrounds. Use system dark colors (~#1C1C1E).
- System colors auto-adapt. Always use system or asset-catalog colors with light/dark variants.
- Shadows are ineffective in dark mode. Use surface elevation and subtle borders instead.
- Test every screen in both modes, with Increase Contrast enabled.

## Spacing (8-point grid)

All spacing in multiples of 4pt (ideally 8pt):

| Token | Value | Use |
|---|---|---|
| xs | 4pt | Icon-to-label, tight element spacing |
| sm | 8pt | Within groups, related items |
| md | 12pt | Compact container padding |
| base | 16pt | Standard padding, margins (iOS 16pt, macOS 20pt) |
| lg | 24pt | Between sections |
| xl | 32pt | Major section breaks |
| xxl | 48pt | Screen-level separation |

- Within-group spacing at most 50% of between-group spacing (Gestalt proximity).
- Example: 8pt between items in a group, 24pt between groups.
- Form fields: 3-5 per section, 16pt between fields, 32pt between sections.

## Layout

- Use `.leading`/`.trailing`, never `.left`/`.right` (RTL support).
- Right-align numbers in columns. Left-align text. Center-align only for buttons, badges, empty states.
- Safe areas: always respect. Use `.ignoresSafeArea()` only for background content.
- Content width: constrain body text to ~680pt max on wide screens.

## Icons (SF Symbols)

- Prefer SF Symbols over custom icons when a matching symbol exists.
- Match symbol weight to adjacent text weight.
- Let symbols size with text styles (`.font(.body)`), not explicit frame sizing.
- Filled variants for selected state, outline for unselected (tab bars).
- Icon-to-label spacing: 6-8pt.

## Motion

- Default animation duration: 200-350ms. Never exceed 500ms for UI transitions.
- Easing: ease-out for entry, ease-in for exit, ease-in-out for within-screen movement.
- Spring for interactive elements: `response: 0.3-0.5, dampingFraction: 0.6-0.85`.
- Cross-fade for state changes: 150-200ms.
- Respect Reduce Motion: replace movement with crossfade or instant.
- Don't animate everything - only meaningful state changes.

### Animation timing reference

| Type | Duration | Curve |
|---|---|---|
| Button press | 50-100ms | ease-out |
| Toggle/state change | 200ms | spring |
| View push/pop | 350ms | ease-in-out |
| Sheet present | 300ms | spring |
| Sheet dismiss | 250ms | ease-in |
| Fade in/out | 150-200ms | ease-in-out |
| Skeleton shimmer | 1500ms | linear, repeat |
| Toast auto-dismiss | 4-8s | - |

## Depth and elevation

- Subtle shadow (cards): 0pt x 1pt blur 3pt, black 8-10% opacity.
- Medium shadow (popovers): 0pt x 4pt blur 12pt, black 12-15% opacity.
- Heavy shadow (modals): 0pt x 8pt blur 24pt, black 15-20% opacity.
- Modal overlay background: dim to 40-60% black opacity.
- Border radius: pick one and use it everywhere (8pt default). Inner radius = outer radius - padding.

## Density

- Compact: 28pt row height (macOS), 36pt (iOS), 8pt padding.
- Regular: 36pt row height (macOS), 44pt (iOS), 12pt padding.
- iOS minimum list row height: 44pt. macOS: 28pt.
