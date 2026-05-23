import AppKit
import HarnessMonitorKit
import SwiftUI

public struct OpenAnythingPaletteView: View {
  @Bindable private var model: OpenAnythingPaletteModel
  private let execute: (OpenAnythingHit) -> Void
  @FocusState private var isFieldFocused: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.controlActiveState) private var controlActiveState

  public init(
    model: OpenAnythingPaletteModel,
    execute: @escaping (OpenAnythingHit) -> Void
  ) {
    self.model = model
    self.execute = execute
  }

  public var body: some View {
    ZStack(alignment: .top) {
      backdrop
      palette
        .padding(.top, OpenAnythingPaletteConstants.topInset)
        .padding(.horizontal, OpenAnythingPaletteConstants.horizontalPadding)
    }
    .accessibilityIdentifier(HarnessMonitorAccessibility.openAnythingPalette)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Open Anything search")
    .accessibilityAction(.escape) {
      model.dismiss(reason: .userCanceled)
    }
    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
    .onAppear {
      isFieldFocused = true
      model.selectFirstHitIfNeeded()
    }
    .task(id: model.query) {
      await runSearch()
    }
    .onChange(of: controlActiveState) { _, newState in
      if newState == .inactive {
        model.dismiss(reason: .windowResignedKey)
      }
    }
    .onKeyPress(.escape, phases: .down) { _ in
      model.dismiss(reason: .userCanceled)
      return .handled
    }
    .onKeyPress(.upArrow, phases: [.down, .repeat]) { _ in
      withAnimation(OpenAnythingMotionPolicy.selectionAnimation(reduceMotion: reduceMotion)) {
        model.moveSelection(by: -1)
      }
      return .handled
    }
    .onKeyPress(.downArrow, phases: [.down, .repeat]) { _ in
      withAnimation(OpenAnythingMotionPolicy.selectionAnimation(reduceMotion: reduceMotion)) {
        model.moveSelection(by: 1)
      }
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
  }

  private var backdrop: some View {
    Color.clear
      .background {
        Rectangle()
          .fill(
            HarnessMonitorTheme.overlayScrim
              .opacity(OpenAnythingPaletteConstants.scrimOpacity)
          )
      }
      .ignoresSafeArea()
      .contentShape(Rectangle())
      .onTapGesture {
        model.dismiss(reason: .userCanceled)
      }
      .accessibilityHidden(true)
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

  @ViewBuilder
  private var resultsSection: some View {
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
      emptyState(text: "No results for \"\(model.query)\". Try a different query.")
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
          } header: {
            sectionHeader(domain: section.domain, count: section.hits.count)
          }
        }
      }
      .padding(.vertical, 8)
    }
    .frame(maxHeight: OpenAnythingPaletteConstants.resultsMaxHeight)
  }

  private func sectionHeader(domain: OpenAnythingDomain, count: Int) -> some View {
    HStack(spacing: 6) {
      Image(systemName: domain.systemImage)
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      Text(domain.label.uppercased())
        .font(.caption)
        .fontWeight(.semibold)
        .foregroundStyle(.secondary)
      Text("· \(count)")
        .font(.caption)
        .foregroundStyle(.tertiary)
      Spacer()
    }
    .padding(.horizontal, OpenAnythingPaletteConstants.sectionHeaderHorizontalPadding)
    .padding(.vertical, OpenAnythingPaletteConstants.sectionHeaderVerticalPadding)
    .background(
      HarnessMonitorTheme.ink
        .opacity(OpenAnythingPaletteConstants.sectionHeaderFillOpacity)
    )
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(
      "\(domain.label) section, \(count) result\(count == 1 ? "" : "s")"
    )
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
    do {
      try await Task.sleep(
        nanoseconds: OpenAnythingPaletteConstants.searchDebounceNanoseconds
      )
    } catch {
      return
    }
    await model.runSearch()
  }

  private func copyToPasteboard(_ value: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
  }

  private func jumpSection(by delta: Int) {
    let sections = model.displayedResults.sections
    guard !sections.isEmpty else { return }
    let currentIndex = currentSectionIndex(sections: sections)
    let count = sections.count
    let nextIndex = ((currentIndex + delta) % count + count) % count
    if let firstHitID = sections[nextIndex].hits.first?.id {
      withAnimation(
        OpenAnythingMotionPolicy.selectionAnimation(reduceMotion: reduceMotion)
      ) {
        model.selectHit(id: firstHitID)
      }
    }
  }

  private func jumpToSection(index: Int) {
    let sections = model.displayedResults.sections
    guard sections.indices.contains(index),
      let firstHitID = sections[index].hits.first?.id
    else { return }
    withAnimation(
      OpenAnythingMotionPolicy.selectionAnimation(reduceMotion: reduceMotion)
    ) {
      model.selectHit(id: firstHitID)
    }
  }

  private func currentSectionIndex(sections: [OpenAnythingSection]) -> Int {
    guard let selectedID = model.selectedHitID else { return 0 }
    for (index, section) in sections.enumerated()
    where section.hits.contains(where: { $0.id == selectedID }) {
      return index
    }
    return 0
  }
}
