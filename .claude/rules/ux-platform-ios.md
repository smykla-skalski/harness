---
globs: "apps/*-ios/**/*.swift"
description: "iOS-specific UX conventions: tab bar, safe areas, navigation bar, gestures, pull-to-refresh."
---

# iOS platform rules

These rules apply to current and future iOS apps in this repository.

## Safe areas

- Always respect safe areas. Interactive controls must remain within safe areas.
- Use `.ignoresSafeArea()` only for background content (images, maps, gradients).
- Bottom safe area: 34pt on Face ID devices. Don't place interactive controls within 34pt of the bottom edge.
- Status bar always visible unless in immersive content (video, photos).

## Tab bar

- Bottom of screen, always visible during in-tab navigation.
- 2-5 tabs maximum. More than 5 uses a "More" tab.
- Icon + short label for each. Filled for selected, outline for unselected.
- Active tab: accent color tint. Inactive: gray.
- Tab bar height: 49pt (83pt with home indicator on Face ID devices).
- Each tab maintains independent navigation state.

## Navigation bar

- Large title for top-level screens (`.navigationBarTitleDisplayMode(.large)`), inline for drill-down.
- Back button: system chevron + previous screen title. Never hide or replace.
- Trailing side: 1-2 action buttons maximum.
- Leading side: back button only (or close for modal presentations).
- Search: `.searchable()` modifier.

## Gestures

- Swipe from left edge navigates back. Never override this system gesture.
- Swipe actions on list rows: trailing for destructive (red), leading for positive actions.
- Full swipe triggers the first action (delete, archive).
- Maximum 3 swipe actions per side.
- Long press for context menus on selectable content.
- Pull-to-refresh: `.refreshable()` modifier for refreshable content.
- Shake to undo is a system behavior. Don't disable it.

## Touch targets

- 44x44pt minimum touch target. No exceptions.
- If the visual element is smaller, expand the hit area.
- Haptic feedback for significant interactions.
- No hover states - design for touch-first.

## Scroll behavior

- Large titles collapse on scroll (automatic with NavigationStack).
- Scroll-to-top: tapping the status bar scrolls to top. Don't interfere.
- Rubber-banding at scroll limits. Never disable.
- System manages content insets for safe areas, bars, and keyboard. Don't manually set unless custom layout.

## Launch

- Cold launch to content: under 400ms target. Absolute max 3 seconds before watchdog kills the app.
- Launch screen matches initial screen layout (same background, layout skeleton). No logos or splash art.
- Don't show onboarding or login on every launch. Once, then straight to content.
- Restore previous state: last tab, scroll position, selection.

## Permissions

- Never request all permissions at launch.
- Ask in context: request camera when user taps "Scan QR code".
- Explain before asking: "We need camera access to scan QR codes" then system prompt.
- If denied: inline message explaining how to enable in Settings, with direct link.
- Graceful degradation: feature unavailable but app still works.
