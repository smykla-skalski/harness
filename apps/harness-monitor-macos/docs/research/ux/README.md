# UX research - comprehensive reference library

This directory contains 10 research documents covering every aspect of building apps with great UX for macOS and iOS. Total: ~4,900 lines of actionable, measurable rules.

These docs are the rationale layer. The enforceable rules distilled from them live in skills under `.claude/skills/swiftui-design-rules`, `swiftui-api-patterns`, `swiftui-performance-macos`, and `swiftui-platform-rules`.

## Documents

| # | File | Lines | Covers |
|---|------|-------|--------|
| 01 | [Apple HIG principles](01-apple-hig-principles.md) | 1094 | Platform conventions, navigation, typography, color, icons, layout, controls, feedback, accessibility, data entry, macOS/iOS specific, Liquid Glass, app lifecycle |
| 02 | [Interaction design patterns](02-interaction-design-patterns.md) | 462 | Direct manipulation, progressive disclosure, Fitts/Hick/Miller laws, feedback loops, error prevention/recovery, consistency, affordances, mental models, microinteractions, Gestalt, information architecture, task flow |
| 03 | [Visual design fundamentals](03-visual-design-fundamentals.md) | 448 | Visual hierarchy, whitespace, 8-point grid, color theory, typography hierarchy, depth/elevation, motion design, iconography, borders, images, dark mode, density, brand expression, responsive layout |
| 04 | [Accessibility requirements](04-accessibility-requirements.md) | 499 | VoiceOver, Dynamic Type, contrast (WCAG), Reduce Motion, Reduce Transparency, Increase Contrast, Bold Text, Switch Control, Full Keyboard Access, pointer a11y, cognitive a11y, screen reader announcements, semantic markup, testing checklist |
| 05 | [SwiftUI best practices](05-swiftui-best-practices.md) | 671 | State management, view composition, navigation, lists, performance, layout, animations, data flow, error handling, platform code, keyboard/focus, drag-drop, menus, settings, window management, anti-patterns |
| 06 | [UX psychology and usability](06-ux-psychology-usability.md) | 420 | Nielsen's 10 heuristics, cognitive load, Don Norman's principles, emotional design, decision architecture, attention, memory/learning, trust/safety, performance perception, UX writing, inclusive design, user testing |
| 07 | [Performance and responsiveness](07-performance-responsiveness.md) | 263 | Response time thresholds, animation FPS, launch time, scroll performance, memory management, network-dependent UI, input responsiveness, background processing, battery/thermal, perceived performance |
| 08 | [Error handling and edge cases](08-error-handling-edge-cases.md) | 318 | Error messages, empty states, loading states, offline/connectivity, destructive actions, boundary conditions, form validation, crash recovery, timeout/retry, accessibility of errors |
| 09 | [Data display patterns](09-data-display-patterns.md) | 335 | Tables/grids, lists, cards, status badges, charts, dates/times, numbers, text content, search/filtering, notifications |
| 10 | [Onboarding and user flows](10-onboarding-user-flows.md) | 351 | First launch, onboarding patterns, settings design, auth flows, wayfinding, multi-step wizards, undo/history, feature discovery, ethical engagement, cross-device, internationalization |

## Key themes across all documents

- **Measurable thresholds**: specific point sizes, contrast ratios, timing in milliseconds, maximum counts
- **Platform-native**: follow Apple conventions, use system controls, respect system settings
- **Accessibility-first**: VoiceOver, Dynamic Type, keyboard navigation, contrast are non-negotiable
- **Progressive disclosure**: show what's needed, hide complexity behind demand
- **Feedback always**: every action gets visible response within 100ms
- **Error prevention over error handling**: constraints, smart defaults, undo over confirmation
- **Performance perception**: skeleton screens, optimistic updates, content-first loading
- **No dark patterns**: respect user attention, no manipulation, easy data export and deletion
