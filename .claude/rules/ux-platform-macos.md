---
globs: "apps/harness-macos/**/*.swift"
description: "macOS-specific UX conventions: menu bar, windows, toolbar, settings, dock, notifications."
---

# macOS platform rules

## Menu bar

- Required menus in order: App menu, File, Edit, View, Window, Help.
- App menu: About, Settings (Cmd+,), Hide (Cmd+H), Hide Others (Cmd+Opt+H), Quit (Cmd+Q).
- Edit menu: Undo (Cmd+Z), Redo (Cmd+Shift+Z), Cut (Cmd+X), Copy (Cmd+C), Paste (Cmd+V), Select All (Cmd+A).
- Disabled menu items are grayed out, never hidden. Hiding breaks muscle memory.
- Keyboard shortcut hints right-aligned in menu items.
- Ellipsis (...) on menu items that open a dialog. No ellipsis for immediate actions.
- Custom menus go between View and Window.
- Every action in the UI must be accessible via the menu bar.

## Windows

- Standard traffic light buttons always top-left. Never hide or replace.
- Red close button closes the window, not the app (unless single-window).
- Cmd+W closes window. Cmd+Q quits.
- Set sensible minimum window size (400x300pt floor). Use `.windowResizability(.contentMinSize)`.
- Restore window position and size on next launch.
- New windows cascade (offset 22pt down and right from previous).
- Full screen support (Ctrl+Cmd+F or green button) for document-based and media apps.
- Window corner radius: 10pt (system standard).

### Window chrome measurements

| Element | Size |
|---|---|
| Title bar | 22pt (standard), 28pt (large title) |
| Unified toolbar | 52pt (standard), 38pt (compact) |
| Traffic light buttons | 12x12pt, 7pt from leading edge, 6pt spacing |
| Window corner radius | 10pt |
| Minimum window size | 400x300pt recommended |

## Toolbar

- SF Symbols at 13pt/regular weight. Icon + optional label.
- Standard placements: `.principal` (center), `.navigation` (leading), `.primaryAction` (trailing).
- Right-click > "Customize Toolbar" should work unless there's a reason not to.
- Separator: `Divider()` between toolbar item groups.

## Sidebar

- Width: 200-280pt default, user-resizable.
- Minimum: 200pt. Collapses entirely below minimum.
- Sidebar items: SF Symbol icon + label, 28-32pt row height.
- Toggle with keyboard shortcut.
- On macOS 26: sidebar gets automatic Liquid Glass. Don't override with opaque backgrounds.

## Settings window

- Opens with Cmd+, (always). Use `Settings` scene in SwiftUI.
- Tab-based with SF Symbol icons (General, Appearance, etc.).
- Fixed window size, non-resizable. Standard width: 500-650pt.
- Settings apply immediately. No Save/Apply/OK button.
- General tab first, Advanced last.
- "Restore Defaults" with confirmation where appropriate.

## Hover and mouse

- Hover states on all interactive elements: subtle background (5-10% opacity accent).
- Cursor changes: pointer for clickable, I-beam for text, resize for edges.
- Tooltips after 500ms hover on non-obvious controls.
- Right-click context menus on all selectable elements.

## Dock

- Badge count for pending items.
- Right-click dock menu: recent items, quick actions.
- Progress indication on dock icon for long operations.
- Dock bounce only for events needing immediate attention.

## Notifications

- Use `UNUserNotificationCenter`.
- Default to banner (auto-dismiss ~5 seconds). Alert only for genuinely urgent information.
- Don't spam. Respect notification settings.
- Up to 4 actions in expanded notification.

## Drag and drop

- Support drag and drop between windows and apps where it makes sense.
- Visual feedback: lift with shadow (1.05x scale), reduce source opacity (0.5).
- Drop target: background color change or dashed border.
- Cancel: Escape key returns to source with spring animation.
- Minimum drop zone: 32x32pt.

## Keyboard shortcuts

Standard shortcuts that must work:

| Action | Shortcut |
|---|---|
| New | Cmd+N |
| Open | Cmd+O |
| Save | Cmd+S |
| Close | Cmd+W |
| Quit | Cmd+Q |
| Undo | Cmd+Z |
| Redo | Cmd+Shift+Z |
| Cut/Copy/Paste | Cmd+X/C/V |
| Select All | Cmd+A |
| Find | Cmd+F |
| Settings | Cmd+, |
| Minimize | Cmd+M |
| Full Screen | Ctrl+Cmd+F |
| Hide | Cmd+H |
