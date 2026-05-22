import HarnessMonitorKit
import SwiftUI

private let openAnythingSearchDebounceNanoseconds: UInt64 = 80_000_000

public struct OpenAnythingPaletteView: View {
  @Bindable private var model: OpenAnythingPaletteModel
  private let execute: (OpenAnythingHit) -> Void
  @FocusState private var isFieldFocused: Bool

  public init(
    model: OpenAnythingPaletteModel,
    execute: @escaping (OpenAnythingHit) -> Void
  ) {
    self.model = model
    self.execute = execute
  }

  public var body: some View {
    ZStack(alignment: .top) {
      Color.black.opacity(0.18)
        .ignoresSafeArea()
        .onTapGesture { model.dismiss() }

      palette
        .padding(.top, 78)
        .padding(.horizontal, 32)
    }
    .accessibilityIdentifier(HarnessMonitorAccessibility.openAnythingPalette)
    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
    .onAppear {
      isFieldFocused = true
      model.selectFirstHitIfNeeded()
    }
    .task(id: model.query) {
      await runSearch()
    }
    .onKeyPress(.escape, phases: .down) { _ in
      model.dismiss()
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
  }

  private var palette: some View {
    VStack(spacing: 0) {
      TextField("Open anything", text: $model.query)
        .textFieldStyle(.plain)
        .font(.title3)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .focused($isFieldFocused)
        .accessibilityIdentifier(HarnessMonitorAccessibility.openAnythingField)
        .onSubmit {
          submitSelectedHit()
        }

      Divider()

      if model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        emptyState("Start typing")
      } else if model.results.isEmpty {
        emptyState("No results")
      } else {
        resultsList
      }
    }
    .frame(maxWidth: 720)
    .frame(maxHeight: 560, alignment: .top)
    .harnessFloatingControlGlass(cornerRadius: 8, tint: nil)
    .shadow(color: .black.opacity(0.25), radius: 28, y: 16)
  }

  private var resultsList: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
        ForEach(model.results.sections) { section in
          Section {
            ForEach(section.hits) { hit in
              resultRow(hit)
            }
          } header: {
            sectionHeader(section.domain.label)
          }
        }
      }
      .padding(.vertical, 8)
    }
    .frame(maxHeight: 480)
  }

  private func sectionHeader(_ title: String) -> some View {
    Text(title.uppercased())
      .font(.caption)
      .fontWeight(.semibold)
      .foregroundStyle(.secondary)
      .padding(.horizontal, 14)
      .padding(.vertical, 6)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(HarnessMonitorTheme.ink.opacity(0.08))
  }

  private func resultRow(_ hit: OpenAnythingHit) -> some View {
    let isSelected = model.selectedHitID == hit.id
    return Button {
      execute(hit)
      model.dismiss()
    } label: {
      HStack(spacing: 12) {
        Image(systemName: hit.record.systemImage)
          .frame(width: 20)
          .foregroundStyle(isSelected ? .white : .secondary)

        VStack(alignment: .leading, spacing: 2) {
          SearchHighlightedText(text: hit.record.title, highlights: hit.highlights.title)
            .lineLimit(1)
          rowSubtitle(hit)
        }

        Spacer(minLength: 12)
        if let trailing = hit.record.trailing {
          SearchHighlightedText(text: trailing, highlights: hit.highlights.trailing)
            .font(.caption)
            .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
            .lineLimit(1)
        }
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 9)
      .contentShape(Rectangle())
    }
    .harnessPlainButtonStyle()
    .background(isSelected ? Color.accentColor : Color.clear)
    .foregroundStyle(isSelected ? .white : .primary)
    .accessibilityIdentifier(HarnessMonitorAccessibility.openAnythingRow(hit.id))
    .accessibilityValue(isSelected ? "selected" : "not selected")
    .overlay(alignment: .trailing) {
      if isSelected {
        AccessibilityTextMarker(
          identifier: HarnessMonitorAccessibility.openAnythingSelectedState,
          text: hit.id
        )
      }
    }
  }

  @ViewBuilder
  private func rowSubtitle(_ hit: OpenAnythingHit) -> some View {
    if let subtitle = hit.record.subtitle {
      SearchHighlightedText(text: subtitle, highlights: hit.highlights.subtitle)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
  }

  private func emptyState(_ text: String) -> some View {
    Text(text)
      .font(.callout)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity)
      .padding(.vertical, 32)
      .accessibilityIdentifier(HarnessMonitorAccessibility.openAnythingEmptyState)
  }

  private func submitSelectedHit() {
    guard let hit = model.selectedHit else { return }
    execute(hit)
    model.dismiss()
  }

  private func runSearch() async {
    do {
      try await Task.sleep(nanoseconds: openAnythingSearchDebounceNanoseconds)
    } catch {
      return
    }
    await model.runSearch()
  }
}
