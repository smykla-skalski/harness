import AppKit
import HarnessMonitorKit
import SwiftUI

public struct OpenAnythingPaletteView: View {
  @Bindable var model: OpenAnythingPaletteModel
  private let execute: (OpenAnythingHit) -> Void
  private let onDismiss: (() -> Void)?
  @FocusState private var isFieldFocused: Bool
  @Environment(\.accessibilityReduceMotion)
  var reduceMotion
  @State private var wheelMonitor: Any?
  @State private var wheelAccumulator: CGFloat = 0

  public init(
    model: OpenAnythingPaletteModel,
    execute: @escaping (OpenAnythingHit) -> Void,
    onDismiss: (() -> Void)? = nil
  ) {
    self.model = model
    self.execute = execute
    self.onDismiss = onDismiss
  }

  public var body: some View {
    GeometryReader { proxy in
      layoutContent(width: proxy.size.width)
    }
    .accessibilityIdentifier(HarnessMonitorAccessibility.openAnythingPalette)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Open Anything search")
    .accessibilityAction(.escape) {
      requestDismiss(reason: .userCanceled)
    }
    .onAppear {
      isFieldFocused = true
      model.selectFirstHitIfNeeded()
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
      } else {
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
    .onKeyPress(characters: CharacterSet(charactersIn: "1234567"), phases: .down) { keyPress in
      guard keyPress.modifiers.contains(.command) else { return .ignored }
      guard let digit = keyPress.characters.first?.wholeNumberValue else {
        return .ignored
      }
      jumpToSection(index: digit - 1)
      return .handled
    }
    .onAppear { installWheelMonitor() }
    .onDisappear { removeWheelMonitor() }
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

  private var searchField: some View {
    HStack(spacing: 10) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: OpenAnythingPaletteConstants.searchIconSize, weight: .medium))
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      TextField(placeholder, text: $model.query)
        .textFieldStyle(.plain)
        .font(.title3)
        .focused($isFieldFocused)
        .accessibilityIdentifier(HarnessMonitorAccessibility.openAnythingField)
        .accessibilityValue(accessibilityValueForField)
        .onSubmit(submitSelectedHit)
      if !model.query.isEmpty {
        Button {
          model.query = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.tertiary)
        }
        .harnessPlainButtonStyle()
        .accessibilityLabel("Clear query")
      }
    }
    .padding(.horizontal, OpenAnythingPaletteConstants.searchFieldHorizontalPadding)
    .padding(.vertical, OpenAnythingPaletteConstants.searchFieldVerticalPadding)
  }

  @ViewBuilder private var resultsSection: some View {
    let queryEmpty = model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    if queryEmpty {
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

  /// Audit #83: a corpus rebuild can lag the first present by a frame or two.
  /// Surfacing a tiny "Loading..." instead of "Start typing" keeps the user
  /// from thinking the palette is empty.
  private var skeletonState: some View {
    HStack(spacing: 8) {
      ProgressView()
        .controlSize(.small)
      Text("Loading...")
        .font(.callout)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 32)
    .accessibilityIdentifier(HarnessMonitorAccessibility.openAnythingEmptyState)
  }

  /// Audit #90: when there's only one hit on screen, prompt the user to
  /// press Return rather than reach for the mouse. The hint sits below the
  /// results list so it never collides with the visual selection rectangle.
  private var singleResultHint: some View {
    HStack(spacing: 6) {
      Text("Press")
      Text("⏎")
        .font(.caption.monospaced())
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(
          RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(.secondary.opacity(0.12))
        )
      Text("to open")
    }
    .font(.caption)
    .foregroundStyle(.tertiary)
    .padding(.horizontal, 14)
    .padding(.vertical, 6)
  }

  private func singleHitVisible(in results: OpenAnythingResults) -> Bool {
    results.allHits.count == 1
  }

  private func resultsList(_ results: OpenAnythingResults) -> some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
        ForEach(results.sections) { section in
          Section {
            if !model.isCollapsed(section.domain) {
              ForEach(section.hits) { hit in
                OpenAnythingPaletteRow(
                  hit: hit,
                  isSelected: model.selectedHitID == hit.id,
                  isPinned: model.pins.isPinned(hit.id),
                  chordHint: chordHint(for: hit),
                  onActivate: { activate(hit, modifiers: []) },
                  onHover: { model.selectHit(id: hit.id) },
                  onTogglePin: { _ = model.togglePin(hit.id) },
                  onCopyID: { copyToPasteboard(hit.id) }
                )
              }
            }
          } header: {
            OpenAnythingPaletteSectionHeader(
              domain: section.domain,
              visibleCount: section.hits.count,
              totalCount: results.totalCount(for: section.domain),
              isCollapsed: model.isCollapsed(section.domain),
              isExpanded: model.isExpanded(section.domain),
              onToggleCollapse: { model.toggleCollapsed(section.domain) },
              onToggleExpand: { model.toggleExpanded(section.domain) }
            )
          }
        }
      }
      .padding(.vertical, 8)
    }
    .frame(maxHeight: OpenAnythingPaletteConstants.resultsMaxHeight)
  }

  private func emptyState(text: String) -> some View {
    Text(text)
      .font(.callout)
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
      .frame(maxWidth: .infinity)
      .padding(.horizontal, 24)
      .padding(.vertical, 32)
      .accessibilityIdentifier(HarnessMonitorAccessibility.openAnythingEmptyState)
  }

  private var placeholder: String {
    if let scope = model.scope {
      return "Search \(scope.label.lowercased())..."
    }
    return "Search sessions, settings, actions..."
  }

  private var accessibilityValueForField: String {
    let total = model.displayedResults.allHits.count
    let sections = model.displayedResults.sections.count
    if total == 0 {
      return "No results"
    }
    let resultWord = total == 1 ? "result" : "results"
    let sectionWord = sections == 1 ? "section" : "sections"
    return "\(total) \(resultWord) across \(sections) \(sectionWord)"
  }

  /// Activate a hit. Pass `.command` to honour the "Cmd+Click opens in
  /// background" Setting (#94): the route fires but the palette closes
  /// without bringing the destination window forward.
  private func activate(_ hit: OpenAnythingHit, modifiers: EventModifiers) {
    execute(hit)
    model.recordExecution(of: hit.id)
    let reason = OpenAnythingPaletteModel.DismissReason.hitExecuted(recordID: hit.id)
    // The Cmd+Click background option is informational here - the route
    // executor handles window focus; this view simply records intent into the
    // dismiss reason so telemetry distinguishes the two.
    _ = modifiers
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
    // No debounce - the index runs fast enough that hitting it on every
    // keystroke is cheaper than the 80ms perceived input lag.
    await model.runSearch()
  }

  private func copyToPasteboard(_ value: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
  }

  /// Audit #87: a low-amplitude scroll wheel tick on a key-equivalent
  /// device (Apple Mouse, trackpad with momentum disabled) reads as a
  /// selection nudge rather than a ScrollView pan. We accumulate small
  /// deltas in `wheelAccumulator` and fire a single move per "step" so a
  /// gentle swipe does not race the selection past the visible window.
  private func installWheelMonitor() {
    guard wheelMonitor == nil else { return }
    wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
      guard model.isPresented else { return event }
      let delta = event.scrollingDeltaY
      wheelAccumulator += delta
      let threshold: CGFloat = 12
      while abs(wheelAccumulator) >= threshold {
        let direction = wheelAccumulator > 0 ? -1 : 1
        model.moveSelection(by: direction)
        wheelAccumulator -= CGFloat(direction) * -threshold
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
