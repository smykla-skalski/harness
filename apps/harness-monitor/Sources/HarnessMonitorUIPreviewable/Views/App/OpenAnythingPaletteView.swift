import AppKit
import HarnessMonitorKit
import SwiftUI

/// Carries the palette's measured content size up to the NSPanel host so the
/// floating window can shrink to fit. Without this, the panel stays at its
/// fixed maxWidth x maxHeight and AppKit's cached auto-shadow renders below
/// the visible glass card as a ghost rectangle.
public struct OpenAnythingContentSizePreferenceKey: PreferenceKey {
  public static let defaultValue: CGSize = .zero
  public static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
    value = nextValue()
  }
}

public struct OpenAnythingPaletteView: View {
  @Bindable var model: OpenAnythingPaletteModel
  private let execute: (OpenAnythingHit) -> Void
  private let onDismiss: (() -> Void)?
  private let onContentSizeChange: ((CGSize) -> Void)?
  private let beginKeepingPanelOpenActivation: () -> Void
  private let endKeepingPanelOpenActivation: () -> Void
  @FocusState private var isFieldFocused: Bool
  @State private var wheelMonitor: Any?
  @State private var wheelAccumulator: CGFloat = 0

  public init(
    model: OpenAnythingPaletteModel,
    execute: @escaping (OpenAnythingHit) -> Void,
    onDismiss: (() -> Void)? = nil,
    onContentSizeChange: ((CGSize) -> Void)? = nil,
    beginKeepingPanelOpenActivation: @escaping () -> Void = {},
    endKeepingPanelOpenActivation: @escaping () -> Void = {}
  ) {
    self.model = model
    self.execute = execute
    self.onDismiss = onDismiss
    self.onContentSizeChange = onContentSizeChange
    self.beginKeepingPanelOpenActivation = beginKeepingPanelOpenActivation
    self.endKeepingPanelOpenActivation = endKeepingPanelOpenActivation
  }

  public var body: some View {
    GeometryReader { proxy in
      layoutContent(width: proxy.size.width)
    }
    .overlay(alignment: .topLeading) {
      AccessibilityTextMarker(
        identifier: HarnessMonitorAccessibility.openAnythingPalette,
        text: "Open Anything search"
      )
    }
    .accessibilityAction(.escape) {
      requestDismiss(reason: .userCanceled)
    }
    .onAppear {
      isFieldFocused = true
      model.selectFirstHitIfNeeded()
      if model.isPresented {
        installWheelMonitor()
      }
    }
    .task(id: model.query) {
      await runSearch()
    }
    .onChange(of: model.isPresented) { _, presented in
      if presented {
        // Panel hides via `alphaValue = 0` (keeping the SwiftUI tree
        // mounted), so `.onAppear` only fires during pre-warm and cannot
        // re-drive focus on subsequent shows. Re-asserting focus on every
        // `isPresented` flip restores first-responder when the panel
        // becomes key after a hide.
        isFieldFocused = true
        model.selectFirstHitIfNeeded()
        installWheelMonitor()
      } else {
        removeWheelMonitor()
        onDismiss?()
      }
    }
    .onKeyPress(.escape, phases: .down) { _ in
      requestDismiss(reason: .userCanceled)
      return .handled
    }
    .onKeyPress(.upArrow, phases: [.down, .repeat]) { _ in
      model.moveSelection(by: -1)
      return .handled
    }
    .onKeyPress(.downArrow, phases: [.down, .repeat]) { _ in
      model.moveSelection(by: 1)
      return .handled
    }
    .onKeyPress(.tab, phases: .down) { keyPress in
      let delta = keyPress.modifiers.contains(.shift) ? -1 : 1
      jumpSection(by: delta)
      return .handled
    }
    .onKeyPress(characters: CharacterSet(charactersIn: "12345678"), phases: .down) { keyPress in
      guard keyPress.modifiers.contains(.command) else { return .ignored }
      guard let digit = keyPress.characters.first?.wholeNumberValue else {
        return .ignored
      }
      jumpToSection(index: digit - 1)
      return .handled
    }
    .onDisappear { removeWheelMonitor() }
    .onPreferenceChange(OpenAnythingContentSizePreferenceKey.self) { size in
      onContentSizeChange?(size)
    }
  }

  @ViewBuilder
  private func layoutContent(width: CGFloat) -> some View {
    if width >= OpenAnythingPaletteConstants.previewPaneActivationWidth {
      HStack(alignment: .top, spacing: 16) {
        palette
        OpenAnythingPalettePreviewPane(hit: model.selectedHit)
          .frame(maxHeight: OpenAnythingPaletteConstants.maxHeight, alignment: .top)
          .harnessFloatingControlGlass(
            cornerRadius: OpenAnythingPaletteConstants.cornerRadius,
            tint: nil
          )
          .shadow(
            color: .black.opacity(OpenAnythingPaletteConstants.shadowOpacity),
            radius: OpenAnythingPaletteConstants.shadowRadius,
            y: OpenAnythingPaletteConstants.shadowYOffset
          )
      }
      .frame(maxWidth: .infinity, alignment: .top)
    } else {
      palette
    }
  }

  private func requestDismiss(reason: OpenAnythingPaletteModel.DismissReason) {
    model.dismiss(reason: reason)
  }

  private var palette: some View {
    VStack(spacing: 0) {
      searchField
      Divider()
      resultsSection
      Divider()
      OpenAnythingPaletteFooter(recordCount: model.recordCount)
    }
    .frame(maxWidth: OpenAnythingPaletteConstants.maxWidth)
    .fixedSize(horizontal: false, vertical: true)
    .background {
      GeometryReader { proxy in
        Color.clear
          .preference(key: OpenAnythingContentSizePreferenceKey.self, value: proxy.size)
      }
    }
    .harnessFloatingControlGlass(
      cornerRadius: OpenAnythingPaletteConstants.cornerRadius,
      tint: nil
    )
    .shadow(
      color: .black.opacity(OpenAnythingPaletteConstants.shadowOpacity),
      radius: OpenAnythingPaletteConstants.shadowRadius,
      y: OpenAnythingPaletteConstants.shadowYOffset
    )
  }

  private var searchField: some View {
    HStack(spacing: 10) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: OpenAnythingPaletteConstants.searchIconSize, weight: .medium))
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .accessibilityHidden(true)
      // `prompt:` accepts a styled `Text`, which is the only way to raise
      // the placeholder from SwiftUI's near-invisible `.placeholderText`
      // system color to the `secondaryInk` token. Keep an explicit
      // `.accessibilityLabel` so VoiceOver still names the field after the
      // visible text title is dropped.
      TextField(
        "",
        text: $model.query,
        prompt: Text(placeholder).foregroundStyle(HarnessMonitorTheme.secondaryInk)
      )
      .textFieldStyle(.plain)
      .font(.title3)
      .focused($isFieldFocused)
      .accessibilityLabel(placeholder)
      .accessibilityIdentifier(HarnessMonitorAccessibility.openAnythingField)
      .accessibilityValue(accessibilityValueForField)
      .onSubmit(submitSelectedHit)
      if !model.query.isEmpty {
        Button {
          model.query = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(HarnessMonitorTheme.tertiaryInk)
        }
        .harnessPlainButtonStyle()
        .accessibilityLabel("Clear query")
      }
    }
    .padding(.horizontal, OpenAnythingPaletteConstants.searchFieldHorizontalPadding)
    .padding(.vertical, OpenAnythingPaletteConstants.searchFieldVerticalPadding)
  }

  @ViewBuilder private var resultsSection: some View {
    if model.queryTermIsEmpty {
      if model.recordCount == 0 {
        skeletonState
      } else if model.suggestedResults.isEmpty {
        emptyState(text: "Start typing to search sessions, settings, and actions.")
      } else {
        VStack(spacing: 0) {
          resultsList(model.suggestedResults)
          if singleHitVisible(in: model.suggestedResults) {
            singleResultHint
          }
        }
      }
    } else if model.results.isEmpty {
      // Only declare "no matches" once the search has actually caught up to
      // the current query. Otherwise we are mid-debounce and the panel was
      // flashing "No results for 'a'" before the first search even ran.
      if model.lastSearchedQuery == model.query {
        emptyState(text: "No results for \"\(model.query)\". Try a different query.")
      } else {
        skeletonState
      }
    } else {
      VStack(spacing: 0) {
        resultsList(model.results)
        if singleHitVisible(in: model.results) {
          singleResultHint
        }
      }
    }
  }

  private func singleHitVisible(in results: OpenAnythingResults) -> Bool {
    visibleResults(in: results).hasExactlyOneHit
  }

  private func resultsList(_ results: OpenAnythingResults) -> some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
        ForEach(results.sections) { section in
          let expandsDomain = section.id == section.domain.rawValue
          Section {
            if !model.isCollapsed(sectionID: section.id) {
              ForEach(section.hits) { hit in
                OpenAnythingPaletteRow(
                  hit: hit,
                  isSelected: model.selectedHitID == hit.id,
                  isPinned: model.pins.isPinned(hit.id),
                  chordHint: chordHint(for: hit),
                  onActivate: { activate(hit, modifiers: $0) },
                  onHover: { model.selectHit(id: hit.id) },
                  onTogglePin: { _ = model.togglePin(hit.id) },
                  onCopyID: { copyToPasteboard(hit.id) }
                )
              }
            }
          } header: {
            OpenAnythingPaletteSectionHeader(
              title: section.title,
              systemImage: section.systemImage,
              visibleCount: section.hits.count,
              totalCount: results.totalCount(for: section),
              isCollapsed: model.isCollapsed(sectionID: section.id),
              isExpanded: expandsDomain && model.isExpanded(section.domain),
              onToggleCollapse: {
                model.toggleCollapsed(sectionID: section.id, domain: section.domain)
              },
              onToggleExpand: {
                guard expandsDomain else { return }
                model.toggleExpanded(section.domain)
              }
            )
          }
        }
      }
    }
    .frame(maxHeight: OpenAnythingPaletteConstants.resultsMaxHeight)
    .fixedSize(horizontal: false, vertical: true)
  }

  private var placeholder: String {
    if let scope = model.scope {
      return "Search \(scope.label.lowercased())..."
    }
    return "Search sessions, settings, actions..."
  }

  private var accessibilityValueForField: String {
    let displayedResults = visibleResults(in: model.displayedResults)
    let total = displayedResults.hitCount
    let sections = displayedResults.sections.count
    if total == 0 {
      return "No results"
    }
    let resultWord = total == 1 ? "result" : "results"
    let sectionWord = sections == 1 ? "section" : "sections"
    return "\(total) \(resultWord) across \(sections) \(sectionWord)"
  }

  private func visibleResults(in results: OpenAnythingResults) -> OpenAnythingResults {
    results.excludingHits(inCollapsedSections: model.collapsedSections)
  }

  /// Activate a hit. Pass `.command` to honour the keep-open Setting (#94):
  /// the route fires and the palette stays up for follow-on actions.
  private func activate(_ hit: OpenAnythingHit, modifiers: EventModifiers) {
    let keepsOpen = modifiers.contains(.command) && model.keepsPaletteOpenOnCommandClick
    if keepsOpen {
      beginKeepingPanelOpenActivation()
    }
    execute(hit)
    model.recordExecution(of: hit.id, refreshResults: keepsOpen)
    if keepsOpen {
      endKeepingPanelOpenActivation()
      return
    }
    let reason = OpenAnythingPaletteModel.DismissReason.hitExecuted(recordID: hit.id)
    model.dismiss(reason: reason)
  }

  private func submitSelectedHit() {
    guard let hit = model.selectedHit else { return }
    activate(hit, modifiers: [])
  }

  /// SF Symbol-free chord hint per record so the row can render the
  /// keyboard equivalent that already exists in HarnessMonitorAppCommands.
  /// Returns nil for records that have no global chord today (most rows).
  private func chordHint(for hit: OpenAnythingHit) -> String? {
    guard case .action(let action) = hit.target else { return nil }
    switch action {
    case .settings: return "⌘,"
    case .refresh: return "⌘R"
    default: return nil
    }
  }

  private func runSearch() async {
    guard model.isPresented else { return }
    if !model.queryTermIsEmpty {
      try? await Task.sleep(
        nanoseconds: OpenAnythingPaletteConstants.searchDebounceNanoseconds
      )
      guard !Task.isCancelled, model.isPresented else { return }
    }
    await model.runSearch()
  }

  private func copyToPasteboard(_ value: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
  }

  /// A low-amplitude scroll wheel tick on a key-equivalent device reads as a
  /// selection nudge rather than a ScrollView pan. We accumulate small deltas
  /// in `wheelAccumulator` and fire a single move per "step" so a gentle swipe
  /// does not race the selection past the visible window.
  private func installWheelMonitor() {
    guard wheelMonitor == nil else { return }
    wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
      guard model.isPresented else { return event }
      let delta = event.scrollingDeltaY
      wheelAccumulator += delta
      let threshold: CGFloat = 12
      let stepCount = Int(abs(wheelAccumulator) / threshold)
      if stepCount > 0 {
        let direction = wheelAccumulator > 0 ? -1 : 1
        model.moveSelection(by: direction * stepCount)
        wheelAccumulator -= CGFloat(direction) * -threshold * CGFloat(stepCount)
      }
      return event
    }
  }

  private func removeWheelMonitor() {
    if let monitor = wheelMonitor {
      NSEvent.removeMonitor(monitor)
      wheelMonitor = nil
    }
    wheelAccumulator = 0
  }
}
