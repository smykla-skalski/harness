# SwiftUI best practices - comprehensive reference

## 1. State management

### Property wrappers: when to use each

| Wrapper | Owner? | Scope | Use when |
|---------|--------|-------|----------|
| @State | Yes | View-local | Simple value types owned by this view (Bool, String, Int, enum) |
| @Binding | No | Parent-child | Child view needs read-write access to parent's state |
| @StateObject | Yes | View-local | View creates and owns an ObservableObject (legacy) |
| @ObservedObject | No | Passed in | View receives an ObservableObject from parent (legacy) |
| @EnvironmentObject | No | Environment | Shared ObservableObject injected higher in the tree (legacy) |
| @Observable (macro) | Varies | Modern | Preferred over ObservableObject for new code (iOS 17+/macOS 14+) |
| @Environment | No | System | System values (colorScheme, dynamicTypeSize) or custom keys |
| @AppStorage | Yes | UserDefaults | Persistent preferences (small values only) |
| @SceneStorage | Yes | Scene | Per-window state restoration |
| @FocusState | Yes | View-local | Keyboard/focus management |

### @Observable vs ObservableObject
```swift
// Modern (preferred): @Observable macro
@Observable
class ViewModel {
    var items: [Item] = []  // automatic observation
    var isLoading = false
}

// Usage: no wrapper needed for owned, @State for local
struct MyView: View {
    var viewModel: ViewModel  // just a property, observation automatic

    // Or for owned instances:
    @State private var viewModel = ViewModel()
}
```

### State ownership rules
- State lives at the lowest common ancestor of all views that need it
- Pass state down, not up. Events bubble up through closures/actions
- Never duplicate state - single source of truth
- @State is PRIVATE - never pass @State references between unrelated views
- If multiple views need the same data, lift it to a shared model

### Avoiding unnecessary redraws
- @Observable only triggers updates for properties actually read in body
- Split large @Observable classes by domain if views only need subsets
- Use `let` for data that doesn't change after init
- Equatable conformance on model types helps diffing
- Don't put closures or computed values in @State

## 2. View composition

### When to extract a subview
- View body exceeds ~40 lines
- The same layout pattern appears in 2+ places
- A section has its own state management
- Readability: if you need to scroll to understand the view

### Extraction rules
- Pass data down as parameters (init properties), not environment unless truly shared
- Use @Binding only when the child needs write access
- Prefer value types (structs) over reference types for view models when possible
- Name views descriptively: `SessionHeaderCard`, not `Header` or `MyView`

### ViewBuilder
```swift
// Good: reusable container with custom content
struct Card<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
        .padding()
        .background(.regularMaterial)
        .cornerRadius(12)
    }
}
```

### View modifiers vs wrapper views
- Modifier: for appearance changes, accessibility, layout tweaks
- Wrapper view: for complex behavior, state management, conditional content
- Create custom view modifiers for repeated modifier chains

```swift
// Custom modifier for repeated patterns
struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(.background)
            .cornerRadius(12)
            .shadow(radius: 2, y: 1)
    }
}

extension View {
    func cardStyle() -> some View {
        modifier(CardStyle())
    }
}
```

## 3. Navigation

### NavigationStack (iOS 16+ / macOS 13+)
```swift
// Programmatic navigation with type-safe path
@State private var path = NavigationPath()

NavigationStack(path: $path) {
    List(items) { item in
        NavigationLink(value: item) {
            ItemRow(item: item)
        }
    }
    .navigationDestination(for: Item.self) { item in
        ItemDetail(item: item)
    }
}
```

### NavigationSplitView (macOS primary)
```swift
NavigationSplitView {
    // Sidebar (auto glass on macOS 26)
    List(selection: $selectedItem) {
        ForEach(items) { item in
            NavigationLink(value: item) { Label(item.name, systemImage: item.icon) }
        }
    }
} detail: {
    if let selectedItem {
        ItemDetail(item: selectedItem)
    } else {
        ContentUnavailableView("Select an item", systemImage: "doc")
    }
}
```

### Sheet and modal presentation
```swift
// Sheet
.sheet(isPresented: $showSettings) {
    SettingsView()
}

// Sheet with item binding
.sheet(item: $selectedItem) { item in
    ItemEditor(item: item)
}

// Confirmation dialog
.confirmationDialog("Delete item?", isPresented: $showDelete) {
    Button("Delete", role: .destructive) { deleteItem() }
    Button("Cancel", role: .cancel) { }
}

// Alert
.alert("Error", isPresented: $showError) {
    Button("Retry") { retry() }
    Button("Cancel", role: .cancel) { }
} message: {
    Text(errorMessage)
}
```

### Navigation anti-patterns
- Don't nest NavigationStack/NavigationSplitView inside each other
- Don't use NavigationLink with destination closure (legacy) - use value-based
- Don't put navigation logic in views - move to a coordinator/router if complex
- Don't navigate on appear without user action (disorienting)

## 4. Lists and collections

### List vs LazyVStack
- List: for standard list UI with built-in selection, swipe actions, section headers
- LazyVStack in ScrollView: for custom layouts, when you don't want List's styling
- LazyVGrid / LazyHGrid: for grid layouts with flexible column/row sizing

### Selection
```swift
// Single selection
@State private var selection: Item.ID?
List(items, selection: $selection) { item in ... }

// Multi-selection
@State private var selection: Set<Item.ID> = []
List(items, selection: $selection) { item in ... }
    .toolbar {
        EditButton() // enables multi-select on iOS
    }
```

### Swipe actions
```swift
ForEach(items) { item in
    ItemRow(item: item)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { delete(item) } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading) {
            Button { archive(item) } label: {
                Label("Archive", systemImage: "archivebox")
            }
            .tint(.blue)
        }
}
```

### Empty states
```swift
if items.isEmpty {
    ContentUnavailableView {
        Label("No items", systemImage: "tray")
    } description: {
        Text("Items you create will appear here.")
    } actions: {
        Button("Create item") { createItem() }
    }
}
```

### Context menus
```swift
ItemRow(item: item)
    .contextMenu {
        Button { edit(item) } label: {
            Label("Edit", systemImage: "pencil")
        }
        Button { duplicate(item) } label: {
            Label("Duplicate", systemImage: "doc.on.doc")
        }
        Divider()
        Button(role: .destructive) { delete(item) } label: {
            Label("Delete", systemImage: "trash")
        }
    }
```

## 5. Performance

### Reducing body recomputation
- @Observable: only re-evaluates when read properties change (better than ObservableObject)
- Equatable views: implement Equatable on views with complex inputs
- Extract expensive subviews so parent changes don't recompute them
- Avoid storing closures in state (they break equatability)

### Lazy loading
- Use List (inherently lazy) or Lazy* stacks/grids for large collections
- Don't use regular VStack/HStack for 50+ items
- LazyVStack doesn't recycle views by default - use List for true cell recycling
- Prefetch data: use .task to load more items as user approaches end of list

### Image optimization
- Use AsyncImage for network images with placeholder
- Downsample large images to display size (don't decode full resolution)
- Cache images: URLCache for network, NSCache for processed images
- Use .resizable() + .scaledToFit()/.scaledToFill() - don't hardcode image sizes

### Task management
```swift
// Load data tied to view lifecycle
.task {
    await loadData()
}

// Cancel previous task when input changes
.task(id: searchText) {
    try? await Task.sleep(for: .milliseconds(300)) // debounce
    await search(searchText)
}

// Task cancellation is automatic when view disappears
```

## 6. Layout system

### Stack rules
- VStack: vertical arrangement, alignment parameter for horizontal alignment
- HStack: horizontal arrangement, alignment parameter for vertical alignment
- ZStack: overlay/layering, alignment for positioning
- Default spacing: 8pt between items (platform-dependent). Specify explicitly for consistency

### Frame modifiers
```swift
// Fixed size
.frame(width: 200, height: 44)

// Flexible with constraints
.frame(minWidth: 100, maxWidth: .infinity, minHeight: 44)

// Just constrain one dimension
.frame(maxWidth: 600) // for readable text width
.frame(height: 44) // fixed height, flexible width
```

### GeometryReader: use sparingly
- It proposes zero size to children, causing layout issues
- Use as a last resort for truly proportional layouts
- Prefer .containerRelativeFrame (iOS 17+) for relative sizing
- Never use GeometryReader for simple "fill available space" - use .frame(maxWidth: .infinity) instead

### Overlay vs background
```swift
// Background: behind the content
Text("Hello")
    .padding()
    .background(.blue, in: RoundedRectangle(cornerRadius: 8))

// Overlay: on top of the content
Image("photo")
    .overlay(alignment: .bottomTrailing) {
        Text("New").font(.caption).padding(4).background(.red)
    }
```

### Safe area handling
```swift
// Extend content into safe area (for backgrounds)
.ignoresSafeArea(.all, edges: .top) // use for background only

// Add content in safe area inset
.safeAreaInset(edge: .bottom) {
    CustomToolbar()
}
```

## 7. Animations

### Explicit vs implicit
```swift
// Explicit: animation triggered by state change (preferred)
withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
    isExpanded.toggle()
}

// Implicit: animation applied to any change of the modified value
Text("Hello")
    .opacity(isVisible ? 1 : 0)
    .animation(.easeInOut(duration: 0.2), value: isVisible)
```

### Transitions
```swift
// Built-in transitions
if showContent {
    ContentView()
        .transition(.opacity) // fade
        .transition(.slide) // slide from leading
        .transition(.move(edge: .bottom)) // slide from bottom
        .transition(.scale.combined(with: .opacity)) // scale + fade
}
```

### matchedGeometryEffect
```swift
// Hero transitions between views
@Namespace var animation

// In source view
Image(item.image)
    .matchedGeometryEffect(id: item.id, in: animation)

// In destination view
Image(item.image)
    .matchedGeometryEffect(id: item.id, in: animation)
```

### Spring parameters
- response: 0.3-0.5 (lower = faster)
- dampingFraction: 0.5-0.7 (bouncy), 0.7-0.9 (slight bounce), 1.0 (no bounce)
- Interactive elements: response 0.35, dampingFraction 0.75
- Large movements: response 0.5, dampingFraction 0.8
- Subtle state changes: .easeInOut(duration: 0.2) (no spring needed)

### Sensory feedback (iOS 17+)
```swift
// Haptic feedback
.sensoryFeedback(.success, trigger: taskCompleted)
.sensoryFeedback(.error, trigger: errorOccurred)
.sensoryFeedback(.selection, trigger: selectedItem)
.sensoryFeedback(.impact(weight: .medium), trigger: dragEnded)
```

## 8. Data flow

### Unidirectional data flow
```
Model (source of truth)
  -> ViewModel (transforms model for display)
    -> View (renders data, captures user intent)
      -> Action/Event (user tapped, typed, etc.)
        -> Model update (via ViewModel method)
          -> View re-renders
```

### Model layer separation
- Model types: pure data, Codable, Hashable, Identifiable
- ViewModels: @Observable classes that own or reference model data
- Views: read from ViewModel, call methods for actions
- Don't put business logic in views
- Don't put display formatting in model types

### Dependency injection
```swift
// Via environment (for shared dependencies)
@Environment(\.modelContext) var modelContext
@Environment(AuthService.self) var auth

// Via init (for direct dependencies)
struct ItemList: View {
    let items: [Item]
    let onDelete: (Item) -> Void
}
```

## 9. Error handling in UI

### Displaying errors
```swift
@State private var error: LocalizedError?

var body: some View {
    content
        .alert(isPresented: Binding(
            get: { error != nil },
            set: { if !$0 { error = nil } }
        )) {
            Alert(
                title: Text(error?.errorDescription ?? "Error"),
                message: Text(error?.recoverySuggestion ?? ""),
                dismissButton: .default(Text("OK"))
            )
        }
}
```

### Loading states
```swift
enum LoadingState<T> {
    case idle
    case loading
    case loaded(T)
    case error(Error)
}

@State private var state: LoadingState<[Item]> = .idle

var body: some View {
    switch state {
    case .idle:
        Color.clear.task { await load() }
    case .loading:
        ProgressView("Loading...")
    case .loaded(let items):
        ItemList(items: items)
    case .error(let error):
        ContentUnavailableView {
            Label("Error", systemImage: "exclamationmark.triangle")
        } description: {
            Text(error.localizedDescription)
        } actions: {
            Button("Retry") { Task { await load() } }
        }
    }
}
```

## 10. Platform-specific code

### Conditional compilation
```swift
#if os(macOS)
    // macOS-only code
    .frame(minWidth: 600, minHeight: 400)
#elseif os(iOS)
    // iOS-only code
    .navigationBarTitleDisplayMode(.inline)
#endif
```

### Platform-adaptive views
```swift
struct AdaptiveStack<Content: View>: View {
    @Environment(\.horizontalSizeClass) var sizeClass
    @ViewBuilder let content: () -> Content

    var body: some View {
        if sizeClass == .compact {
            VStack(spacing: 12) { content() }
        } else {
            HStack(spacing: 16) { content() }
        }
    }
}
```

### Platform-specific modifiers
```swift
extension View {
    @ViewBuilder
    func macOSOnly<Modified: View>(_ transform: (Self) -> Modified) -> some View {
        #if os(macOS)
        transform(self)
        #else
        self
        #endif
    }
}
```

## 11. Keyboard and focus

### Focus management
```swift
@FocusState private var focusedField: Field?

enum Field: Hashable {
    case search, name, email
}

TextField("Name", text: $name)
    .focused($focusedField, equals: .name)
    .onSubmit { focusedField = .email }

TextField("Email", text: $email)
    .focused($focusedField, equals: .email)
    .onSubmit { submit() }
    .submitLabel(.done)
```

### Keyboard shortcuts (macOS)
```swift
Button("New Item") { createItem() }
    .keyboardShortcut("n", modifiers: .command)

Button("Delete") { deleteItem() }
    .keyboardShortcut(.delete, modifiers: .command)
```

## 12. Drag and drop

```swift
// Draggable
ForEach(items) { item in
    ItemView(item: item)
        .draggable(item) // requires Transferable conformance
}

// Drop destination
.dropDestination(for: Item.self) { items, location in
    handleDrop(items)
    return true
}
```

## 13. Menu and commands

### App-level commands (macOS)
```swift
@main
struct MyApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
            .commands {
                CommandGroup(after: .newItem) {
                    Button("New Project") { createProject() }
                        .keyboardShortcut("n", modifiers: [.command, .shift])
                }
                CommandMenu("Tools") {
                    Button("Run Analysis") { analyze() }
                        .keyboardShortcut("r", modifiers: .command)
                }
            }
    }
}
```

## 14. Settings/preferences

### macOS Settings scene
```swift
@main
struct MyApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
        Settings {
            TabView {
                GeneralSettings()
                    .tabItem { Label("General", systemImage: "gear") }
                AppearanceSettings()
                    .tabItem { Label("Appearance", systemImage: "paintbrush") }
                AdvancedSettings()
                    .tabItem { Label("Advanced", systemImage: "wrench") }
            }
            .frame(width: 450, height: 300)
        }
    }
}
```

### @AppStorage for preferences
```swift
@AppStorage("showSidebar") private var showSidebar = true
@AppStorage("refreshInterval") private var refreshInterval = 300

// Changes persist to UserDefaults and update the view automatically
// Use only for small, simple preference values
// Don't store large data or sensitive info in AppStorage
```

## 15. Window management (macOS)

### Window configuration
```swift
WindowGroup {
    ContentView()
}
.defaultSize(width: 900, height: 600)
.defaultPosition(.center)
// Minimum window size
.windowResizability(.contentMinSize)

// Additional window types
Window("Activity Monitor", id: "activity") {
    ActivityView()
}
.defaultSize(width: 400, height: 300)
.keyboardShortcut("0", modifiers: [.command, .option])
```

### MenuBarExtra
```swift
MenuBarExtra("Status", systemImage: "circle.fill") {
    Button("Show Main Window") { openWindow(id: "main") }
    Divider()
    Button("Quit") { NSApplication.shared.terminate(nil) }
}
.menuBarExtraStyle(.window) // or .menu for simple dropdown
```

## 16. Common anti-patterns

### Don't
- Use `AnyView` (type-erases, breaks diffing). Use `@ViewBuilder`, `Group`, or `some View`
- Store view references in state or observable objects
- Use GeometryReader as first child of a view body
- Perform work in view initializers - use .task or .onAppear
- Use .onAppear for async work when .task handles cancellation automatically
- Force unwrap optionals in views - handle nil states gracefully
- Create @StateObject in a view that doesn't own the lifecycle
- Use Timer.publish when .task with AsyncStream works
- Ignore the id parameter in ForEach (must be stable and unique)
- Use index-based ForEach for mutable collections (use Identifiable)

### Do
- Keep view bodies pure and fast (no side effects, no heavy computation)
- Use value types (structs, enums) for state when possible
- Leverage the environment for dependency injection
- Test view models independently from views
- Use previews extensively during development
- Implement proper Identifiable conformance on model types
- Handle all states: loading, empty, error, loaded, refreshing
