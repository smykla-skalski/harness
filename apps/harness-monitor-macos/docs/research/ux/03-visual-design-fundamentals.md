# Visual design fundamentals - comprehensive reference

## 1. Visual hierarchy

### Tools for directing attention (in order of impact)
1. **Size** - larger elements draw attention first. Headlines 2-3x body text size
2. **Color/contrast** - high contrast or saturated color pops against neutral surroundings
3. **Weight** - bold/heavy type weight stands out from regular weight
4. **Position** - top-left (LTR) gets seen first. Above the fold is primary real estate
5. **Whitespace** - isolated elements (surrounded by space) draw attention
6. **Motion** - animated elements attract attention (use sparingly, respect Reduce Motion)

### Reading patterns
- **F-pattern**: text-heavy pages. Users scan across the top, then down the left side, with shorter horizontal scans. Place primary info at the top and along the left edge
- **Z-pattern**: landing pages, marketing. Eye follows Z: top-left logo, top-right CTA, bottom-left supporting info, bottom-right primary action
- **Visual weight**: heavier elements (darker, larger, bolder) are scanned first regardless of position

### Above-the-fold priorities
- Most important action and key content visible without scrolling
- For macOS: assume 800pt visible height minimum (13" laptop)
- For iOS: assume 680pt visible height (iPhone SE-class, minus navigation/tab bars)
- Critical information density: title + status + 1 primary action visible on first load

### Hierarchy levels (maximum 4-5)
1. **Page title** - largest, boldest. One per screen
2. **Section title** - clearly subordinate to page title
3. **Item title** - within sections, regular weight
4. **Body content** - default text style
5. **Metadata/caption** - smallest, lighter color

## 2. Whitespace and breathing room

### Minimum spacing rules (8-point grid)
- Between unrelated sections: 32-48pt
- Between related sections: 16-24pt
- Between items in a list/group: 8-12pt
- Between a label and its content: 4-8pt
- Inside a card/container: 12-16pt padding on all sides
- Between text lines (line height): body text at 1.4-1.6x font size

### When dense is OK
- Data tables with many columns: 8pt cell padding, 28pt row height
- Toolbars and control bars: 4-8pt between icons
- List views showing many items: 28-32pt row height (macOS), 44pt minimum (iOS)
- Code displays: tighter line height (1.2-1.3x)

### When spacious is needed
- Reading content (articles, descriptions): generous margins, 1.5x+ line height
- Onboarding and empty states: center content with large surrounding space
- Settings forms: 16pt+ between fields, 32pt+ between sections
- Dashboard cards: 16pt+ between cards

### Visual clutter indicators
- More than 3 different font sizes visible at once
- More than 5 different colors in non-data-visualization content
- Borders on all sides of every element (use whitespace instead)
- Less than 8pt between interactive elements
- More than 50% of screen area filled with text/controls (aim for 40% content, 60% space for reading-focused screens)

## 3. Grid systems

### 8-point grid
- All dimensions are multiples of 8pt (with 4pt for fine adjustments)
- Spacing: 4, 8, 12, 16, 20, 24, 32, 40, 48, 56, 64, 80, 96
- Component heights: multiples of 8 (24, 32, 40, 48, 56)
- Icon sizes: 16, 20, 24, 28, 32 (4pt increments OK for icons)
- Why 8: divides cleanly into screen resolutions, scales well at 1x/2x/3x

### Column grids
- macOS: 12-column grid for full-width layouts
- iPad: 8-column in compact, 12-column in regular width
- iPhone: 4-column grid (portrait), 6-column (landscape)
- Column gutter: 16-20pt
- Outer margins: 16pt (phone), 20pt (tablet/desktop)

### Baseline grid
- Align text baselines across columns for professional look
- Baseline increment: 4pt (half the grid unit)
- Every line of text baseline sits on a 4pt increment
- Padding between text elements should maintain baseline alignment

### Responsive breakpoints (SwiftUI size classes)
- Compact width: iPhone portrait, iPad slide-over (< 600pt)
- Regular width: iPad full, macOS windows (>= 600pt)
- Compact height: iPhone landscape (< 400pt)
- Regular height: most configurations
- Design for compact first, enhance for regular

## 4. Color theory applied to UI

### 60-30-10 rule
- 60%: dominant/background color (neutrals, background surfaces)
- 30%: secondary color (cards, sections, grouped backgrounds)
- 10%: accent color (buttons, links, highlights, active states)
- This ratio creates visual balance and lets the accent color draw attention

### Color for status
- Red (#FF3B30 light / #FF453A dark): error, destructive, critical, stop
- Orange (#FF9500 / #FF9F0A): warning, caution, needs attention
- Yellow (#FFCC00 / #FFD60A): advisory, non-critical notice
- Green (#34C759 / #30D158): success, positive, active, healthy
- Blue (#007AFF / #0A84FF): informational, link, in-progress, interactive
- Gray (#8E8E93 / #636366): neutral, disabled, inactive, unknown
- Never use color alone to convey meaning - pair with icon, text, or pattern

### Color temperature
- Cool colors (blue, green, purple): professional, calm, trustworthy. Good for backgrounds
- Warm colors (red, orange, yellow): energetic, urgent, attention-grabbing. Good for alerts and CTAs
- Neutral colors (gray, white, black): stable, clean. Primary for text and backgrounds

### Colorblind-safe palette
- Avoid red/green as the only distinguishing pair (affects 8% of males)
- Use shape, pattern, or text alongside color
- Blue/orange is distinguishable by most color vision types
- Test with color blindness simulators
- System semantic colors handle this partially, but verify custom colors

### Dark mode color adjustments
- Background: dark gray (#1C1C1E), not pure black (#000000)
- Elevation: lighter shades for elevated surfaces (#2C2C2E, #3A3A3C, #48484A)
- Text: off-white (#F2F2F7) for primary, not pure white (#FFFFFF) except for emphasis
- Reduce saturation of colors slightly (system colors auto-adjust)
- Borders: subtle, 10-15% white opacity
- Shadows: minimal or none (rely on surface elevation instead)

## 5. Typography hierarchy

### Heading levels
- H1 (largeTitle): one per screen, page title. 34pt (iOS) / 26pt (macOS)
- H2 (title): section headers. 28pt / 22pt. 32pt+ spacing above
- H3 (title2): subsection headers. 22pt / 17pt. 24pt+ spacing above
- H4 (title3): card or group titles. 20pt / 15pt
- Body: primary content. 17pt / 13pt
- Caption: metadata, timestamps. 12pt / 10pt

### Line height ratios
- Headlines: 1.1-1.2x font size (tight)
- Body text: 1.4-1.6x font size (comfortable reading)
- Captions: 1.2-1.4x font size
- Code/monospace: 1.3-1.5x font size
- In SwiftUI: use text styles which have built-in line spacing, or .lineSpacing() modifier

### Maximum line length
- Body text: 45-75 characters per line (66 characters optimal)
- On macOS: constrain text content to ~680pt width maximum
- On wide screens: use columns or center content with margins
- Code blocks: 80-120 characters, horizontal scroll beyond that
- In SwiftUI: .frame(maxWidth:) or .readingContentWidth(.standard)

### Paragraph spacing
- Between paragraphs: 0.5-1.0x the line height of body text
- Between heading and first paragraph: 0.5x heading size
- Don't use blank lines (double spacing) - use explicit paragraph spacing

### Monospace usage
- Code snippets and blocks
- Terminal output
- IDs, hashes, UUIDs
- File paths
- IP addresses and ports
- Use SF Mono (system) or custom coding font
- Size monospace same as or 1pt smaller than surrounding body text

### Font weight hierarchy
- Regular (400): body text, descriptions
- Medium (500): emphasized body, labels
- Semibold (600): section headers, important labels
- Bold (700): page titles, primary headers
- Use maximum 2-3 weights per screen
- Don't use light/ultralight for UI text (readability issues at small sizes)

## 6. Depth and elevation

### Shadow specifications
- Subtle (cards, buttons): 0pt x 1pt blur 3pt, black 8-10% opacity
- Medium (popovers, dropdown menus): 0pt x 4pt blur 12pt, black 12-15% opacity
- Heavy (modals, sheets): 0pt x 8pt blur 24pt, black 15-20% opacity
- Dark mode: shadows nearly invisible. Use surface color elevation instead

### Layer order (bottom to top, z-index)
1. Base background (window/screen background)
2. Content surface (cards, sections)
3. Elevated content (selected items, hover states)
4. Navigation elements (sidebars, tab bars, toolbars)
5. Floating controls (FABs, action buttons)
6. Overlays (dropdown menus, popovers)
7. Sheets and modals
8. Alerts and dialogs
9. System overlays (notifications, status indicators)

### Material blur (macOS/iOS)
- .ultraThinMaterial: barely visible blur, mostly transparent
- .thinMaterial: light blur, shows through
- .regularMaterial: standard system blur
- .thickMaterial: heavier blur, less shows through
- .ultraThickMaterial: heavy blur, close to opaque
- Materials blur behind the window (macOS), not behind sibling views
- Use for toolbars, sidebars, overlays over dynamic content

## 7. Motion design

### Duration guidelines
- Micro-interactions (press, toggle): 50-150ms
- State changes (expand, show/hide): 200-300ms
- View transitions (push, modal): 300-500ms
- Content loading shimmer cycle: 1500-2000ms
- Never exceed 700ms for any UI animation (feels sluggish)

### Easing curves
- **ease-out** (decelerate): elements entering the screen. Starts fast, slows to stop. Natural "arrival" feel
- **ease-in** (accelerate): elements leaving the screen. Starts slow, speeds up. Natural "departure" feel
- **ease-in-out**: elements moving within the screen. Smooth start and stop
- **spring**: interactive elements (drag release, toggle, bounce). Parameters: response 0.3-0.5, dampingFraction 0.6-0.85
- **linear**: only for continuous animations (progress bars, loading spinners, shimmer)

### SwiftUI animation specifics
- `.animation(.spring(response: 0.35, dampingFraction: 0.75))` - standard interactive spring
- `.animation(.easeInOut(duration: 0.25))` - standard state transition
- `withAnimation(.spring) { state = newValue }` - explicit animation trigger
- `.transition(.opacity)` - fade in/out on insert/remove
- `.transition(.move(edge: .bottom).combined(with: .opacity))` - slide + fade for sheets
- `.matchedGeometryEffect` - hero transitions between views

### Choreography principles
- Related elements animate together or in quick sequence (50ms stagger)
- Parent before children: container appears, then content fades in
- Stagger list items: 30-50ms per item, max 5 items staggered (rest appear with last)
- Direction matters: new content enters from the direction of navigation
- Exit opposite to entry: if content entered from right, it exits to the right when going back

### What NOT to animate
- Loading spinners appearing (just show instantly)
- Error messages appearing (instant, don't delay the information)
- Text content changes (cross-fade at most)
- Color changes (cross-fade, 150ms max)
- Content the user is reading (don't move text while someone reads)

### Reduce Motion alternatives
- Replace slide transitions with cross-fade
- Replace spring animations with linear/instant
- Remove parallax effects entirely
- Remove bounce/overshoot
- Keep essential state-change feedback (opacity change is fine)
- Remove decorative animations entirely

## 8. Iconography design

### Consistent stroke weight
- Match icon stroke weight to the adjacent text font weight
- SF Symbols: .ultralight through .black, choose to match text
- Custom icons: 1.5pt stroke for body text context, 2pt for headers
- All icons on the same screen should use the same weight

### Optical alignment
- Geometric centering often looks off-center. Adjust visually
- Play buttons: shift right ~1pt to appear centered (triangle visual weight is left-heavy)
- Circle icons: slightly larger than square icons to appear the same size
- Triangular/pointed icons: extend slightly beyond the bounding box

### Icon-to-label spacing
- Inline (icon + text in a row): 6-8pt spacing
- List items (leading icon + text): 12-16pt spacing
- Tab bar items (icon above text): 2-4pt spacing
- Button (icon + label): 4-8pt spacing

### Icon sizing relative to text
- Inline with body text: match font cap-height (not full size)
- List item leading icons: 20-24pt at body text size
- Toolbar icons: 16-20pt (macOS), 22-28pt (iOS)
- Tab bar icons: 24-28pt (iOS)
- Use .imageScale(.small/.medium/.large) for SF Symbols

## 9. Border and divider usage

### Lines vs whitespace
- Prefer whitespace for section separation (cleaner, less visual noise)
- Use lines when items are dense and need clear boundaries (data tables)
- Use lines to separate action areas (toolbar from content, footer from content)
- Don't use both borders AND whitespace redundantly

### Border radius
- Consistency: pick one radius and use it everywhere (8pt is a good default)
- Nested elements: inner radius = outer radius - padding
- Buttons: 6-8pt radius
- Cards: 8-12pt radius
- Input fields: 6-8pt radius
- Modals/sheets: 12-16pt top corners
- Never mix rounded and sharp corners on the same screen

### Hairline dividers
- Use 0.5pt (hairline) dividers for subtle separation in lists
- 1pt dividers for stronger separation
- Divider color: .separator system color (adapts to light/dark)
- Inset dividers: align with content start (skip the icon column in lists)
- Don't use full-width dividers if items have clear spacing

### Border on interactive elements
- Text fields: 1pt border in neutral state, 2pt in focused state (accent color)
- Buttons: 1pt border for secondary/outlined style
- Cards: 0.5-1pt border or shadow (not both)
- Selected items: 2pt accent color border or background highlight

## 10. Image and media

### Aspect ratios
- Profile photos/avatars: 1:1 (square, usually circular crop)
- Thumbnails: 1:1 or 4:3
- Hero images: 16:9 or 2:1
- App screenshots: device aspect ratio
- Always maintain aspect ratio - never stretch or skew
- Use .scaledToFill with .clipped for filling containers, .scaledToFit for full visibility

### Placeholder strategies
- Skeleton/shimmer: gray rectangles with subtle pulse animation matching the content layout
- Blur-up: show tiny low-res version (8x8px) blurred, then load full resolution
- Dominant color: extract dominant color from thumbnail, show as placeholder
- Icon placeholder: generic content-type icon (photo, document, person silhouette)
- Never show a broken image icon in production

### Loading states for media
- Shimmer pulse: 1500ms cycle, left-to-right gradient sweep
- Skeleton matches final layout dimensions (prevent layout shift)
- Fade in on load: 200ms cross-fade from placeholder to actual content
- Progressive JPEG: show low-quality first, sharpen as data loads

### Rounded corners on media
- Match container border radius
- Profile photos: fully circular (.clipShape(Circle()))
- Thumbnails in lists: 4-8pt radius
- Hero/feature images: 8-12pt radius
- Use .cornerRadius or .clipShape consistently

## 11. Dark mode design

### Surface elevation (lighter = higher)
- Level 0 (base): system background (#000000 or #1C1C1E)
- Level 1 (cards, groups): #1C1C1E or #2C2C2E
- Level 2 (elevated content): #2C2C2E or #3A3A3C
- Level 3 (popovers, menus): #3A3A3C or #48484A
- Each level adds approximately 5-8% white to the background

### Dark mode do's
- Use semantic/system colors that auto-adapt
- Test all custom colors in both modes (Asset catalog variants)
- Increase icon stroke weight slightly (thin strokes disappear on dark backgrounds)
- Use desaturated/vibrant versions of brand colors
- Maintain 4.5:1 contrast for text

### Dark mode don'ts
- Don't use pure black (#000000) for backgrounds (too harsh, OLED only)
- Don't use pure white (#FFFFFF) for large text areas (too bright)
- Don't just invert colors (elevation logic reverses in dark mode)
- Don't use the same shadow parameters (shadows invisible on dark)
- Don't assume your light-mode colors work unchanged

## 12. Density and information display

### Density modes
- Compact: 28pt row height (macOS), 36pt (iOS), 8pt padding
- Regular: 36pt row height (macOS), 44pt (iOS), 12pt padding
- Spacious: 48pt row height, 16pt padding
- Let users choose density for data-heavy interfaces
- Default to regular on iOS, compact or regular on macOS

### Truncation rules
- Single line: truncate with ellipsis at trailing end
- Multi-line: clamp to 2-3 lines with "..." at the end of last visible line
- Show full content on hover (tooltip, macOS) or tap (expand, iOS)
- Never truncate titles in navigation (wrap or use smaller font instead)
- File names: truncate middle ("my_very_lo...ument.pdf")
- Tooltip for any truncated content

### Data tables
- Minimum column width: 60pt (narrow data), 120pt (text content)
- Row height: 28-32pt (compact), 36-40pt (regular)
- Cell padding: 8pt horizontal, 4pt vertical (compact), 12pt/8pt (regular)
- Alternating row colors: optional, 3-5% background tint difference
- Sticky header row for scrollable tables
- Horizontal scroll for wide tables, don't squeeze columns below minimum

## 13. Brand expression within platform

### Accent color
- One primary accent color for the entire app
- Set via .tint or accentColor in SwiftUI
- Used for: interactive elements, links, active tab indicators, toggle on-state, progress
- Don't override system controls with custom colors for standard interactions
- Respect user's system accent color preference (optional - most apps set their own)

### Custom fonts
- Use sparingly: marketing screens, app name, feature headers
- Never for body text, buttons, or navigation labels (use system fonts)
- Always provide fallback to system font
- Ensure Dynamic Type scaling works with custom fonts
- License fonts properly for app distribution

### Where to express brand personality
- App icon and launch screen
- Onboarding illustrations
- Empty state illustrations
- About screen
- Custom accent color throughout
- Subtle animation personality
- NOT in system controls, alerts, or standard navigation

## 14. Responsive and adaptive layout

### Size class strategy
- Design for compact width first (iPhone portrait)
- Enhance for regular width (iPad, macOS)
- Compact width: single column, full-width content, bottom navigation
- Regular width: multi-column, sidebar navigation, side-by-side content

### Layout adaptation patterns
- Stack direction: HStack in regular width -> VStack in compact width
- Sidebar: visible in regular -> hidden/overlay in compact
- Master-detail: side-by-side in regular -> stack in compact
- Grid columns: 4 in regular -> 2 in compact
- Use ViewThatFits for automatic adaptation
- Use @Environment(\.horizontalSizeClass) for manual control

### Orientation changes
- Layout adapts immediately (no delay)
- Maintain scroll position and selection state
- Don't force orientation unless truly needed (video playback)
- Test all screens in both orientations on iPhone and iPad

### Multitasking (iPad)
- Support all split-view sizes (1/3, 1/2, 2/3)
- Adapt layout to available width using size classes
- Don't require minimum width beyond system minimums
- Support Slide Over (compact width overlay)
- Drag and drop between apps

---

## Quick reference: the 8-point spacing scale

| Token | Value | Usage |
|-------|-------|-------|
| xxs | 4pt | Label-to-value, icon padding |
| xs | 8pt | Within tight groups, inline spacing |
| sm | 12pt | List item padding, card inner |
| md | 16pt | Standard padding, section margins |
| lg | 24pt | Between sections, card gaps |
| xl | 32pt | Major section spacing |
| xxl | 48pt | Screen-level separation |
| xxxl | 64pt | Hero spacing, major landmarks |
