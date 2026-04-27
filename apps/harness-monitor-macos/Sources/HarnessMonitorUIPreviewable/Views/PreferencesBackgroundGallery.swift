import SwiftUI

private enum PreferencesBackgroundGalleryRecents {
  static func items(
    from recentStorageValues: String,
    maxItems: Int
  ) -> [HarnessMonitorBackgroundSelection] {
    guard !recentStorageValues.isEmpty else {
      return []
    }

    var recentItems: [HarnessMonitorBackgroundSelection] = []
    var seenStorageValues = Set<String>()

    for storedValue in recentStorageValues.split(separator: "|").map(String.init) {
      let selection = HarnessMonitorBackgroundSelection.decode(storedValue)
      guard selection.storageValue == storedValue else {
        continue
      }
      guard seenStorageValues.insert(selection.storageValue).inserted else {
        continue
      }

      recentItems.append(selection)
      if recentItems.count == max(0, maxItems) {
        break
      }
    }

    return recentItems
  }

  static func updatedStorageValues(
    _ recentStorageValues: String,
    with background: HarnessMonitorBackgroundSelection,
    maxItems: Int
  ) -> String {
    var updatedValues = items(from: recentStorageValues, maxItems: maxItems).map(\.storageValue)
    updatedValues.removeAll { $0 == background.storageValue }
    updatedValues.insert(background.storageValue, at: 0)
    return Array(updatedValues.prefix(max(0, maxItems))).joined(separator: "|")
  }

  static func stateLabel(for recentItems: [HarnessMonitorBackgroundSelection]) -> String {
    "recent=\(recentItems.map(\.preferencesStateValue).joined(separator: "|"))"
  }
}

enum PreferencesBackgroundGalleryPrefetchPlan {
  static let initialLimit = 12

  static func selections(
    options: [HarnessMonitorBackgroundSelection],
    recentItems: [HarnessMonitorBackgroundSelection],
    selectedBackground: HarnessMonitorBackgroundSelection,
    visibleIDs _: [String]
  ) -> [HarnessMonitorBackgroundSelection] {
    var plannedSelections: [HarnessMonitorBackgroundSelection] = []
    var seenStorageValues = Set<String>()

    func append(_ selection: HarnessMonitorBackgroundSelection) {
      guard seenStorageValues.insert(selection.storageValue).inserted else {
        return
      }
      plannedSelections.append(selection)
    }

    for selection in options.prefix(max(0, initialLimit)) {
      append(selection)
    }

    append(selectedBackground)
    for selection in recentItems {
      append(selection)
    }

    return plannedSelections
  }
}

struct PreferencesBackgroundGallery: View {
  @Binding var selection: String
  @Binding var backdropModeRawValue: String
  let selectedBackground: HarnessMonitorBackgroundSelection
  let collection: BackgroundCollection
  @ScaledMetric(relativeTo: .body)
  private var previewHeight = 96.0
  @AppStorage(HarnessMonitorBackgroundDefaults.recentKey)
  private var recentStorageValues = ""

  private static let maxRecents = 8
  private static let recentTileWidth: CGFloat = 140

  private var isBackdropDisabled: Bool {
    HarnessMonitorBackdropMode(rawValue: backdropModeRawValue) == HarnessMonitorBackdropMode.none
  }

  private var hasStoredRecents: Bool {
    !recentItems.isEmpty
  }

  private var options: [HarnessMonitorBackgroundSelection] {
    switch collection {
    case .featured: HarnessMonitorBackgroundSelection.bundledLibrary
    case .native: HarnessMonitorBackgroundSelection.systemLibrary
    }
  }

  private var recentItems: [HarnessMonitorBackgroundSelection] {
    PreferencesBackgroundGalleryRecents.items(
      from: recentStorageValues,
      maxItems: Self.maxRecents
    )
  }

  private var recentStateLabel: String {
    PreferencesBackgroundGalleryRecents.stateLabel(for: recentItems)
  }

  private let columns = [
    GridItem(.adaptive(minimum: 180, maximum: 220), spacing: HarnessMonitorTheme.spacingMD)
  ]

  private var galleryPrefetchSelections: [HarnessMonitorBackgroundSelection] {
    PreferencesBackgroundGalleryPrefetchPlan.selections(
      options: options,
      recentItems: recentItems,
      selectedBackground: selectedBackground,
      visibleIDs: []
    )
  }

  private var galleryPrefetchSignature: String {
    galleryPrefetchSelections.map(\.storageValue).joined(separator: "|")
  }

  var body: some View {
    Group {
      if isBackdropDisabled {
        VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingLG) {
          VStack(spacing: HarnessMonitorTheme.spacingSM) {
            Image(systemName: "photo.on.rectangle.angled")
              .font(.system(size: 36))
              .foregroundStyle(.tertiary)
            Text("Background image requires a backdrop")
              .scaledFont(.headline)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: true, vertical: false)
            Text("Set the backdrop to Window or Content to choose a background image")
              .scaledFont(.subheadline)
              .foregroundStyle(.tertiary)
              .fixedSize(horizontal: true, vertical: false)
          }
          .frame(maxWidth: .infinity)
          .padding(.vertical, HarnessMonitorTheme.spacingXL)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(HarnessMonitorAccessibility.preferencesBackgroundGallery)
        .task(id: recentStorageValues) {
          guard hasStoredRecents else { return }
          await BackgroundThumbnailCache.shared.prefetch(recentItems)
        }
      } else if options.isEmpty {
        ContentUnavailableView(
          "No wallpapers found",
          systemImage: "photo",
          description: Text("macOS wallpapers were not found on this Mac")
        )
      } else {
        VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingLG) {
          if hasStoredRecents {
            recentBackgroundsRow
          }

          LazyVGrid(columns: columns, alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
            ForEach(options) { background in
              PreferencesBackgroundTile(
                background: background,
                isSelected: background.storageValue == selectedBackground.storageValue,
                previewHeight: previewHeight,
                select: { select(background) }
              )
            }
          }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(HarnessMonitorAccessibility.preferencesBackgroundGallery)
        .task(id: galleryPrefetchSignature) {
          try? await Task.sleep(for: .milliseconds(180))
          guard !Task.isCancelled else { return }
          await BackgroundThumbnailCache.shared.prefetch(galleryPrefetchSelections)
        }
      }
    }
    .overlay {
      if HarnessMonitorUITestEnvironment.accessibilityMarkersEnabled {
        AccessibilityTextMarker(
          identifier: HarnessMonitorAccessibility.preferencesBackgroundRecentState,
          text: recentStateLabel
        )
      }
    }
  }

  private var recentBackgroundsRow: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      Text("Recent")
        .scaledFont(.subheadline)
        .foregroundStyle(.secondary)

      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: HarnessMonitorTheme.spacingSM) {
          ForEach(recentItems) { background in
            PreferencesBackgroundTile(
              background: background,
              isSelected: background.storageValue == selectedBackground.storageValue,
              previewHeight: previewHeight * 0.7,
              select: { select(background) }
            )
            .frame(width: Self.recentTileWidth)
          }
        }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.preferencesBackgroundRecentsSection)
  }

  private func select(_ background: HarnessMonitorBackgroundSelection) {
    selection = background.storageValue
    let currentBackdropMode = HarnessMonitorBackdropMode(rawValue: backdropModeRawValue)
    if currentBackdropMode == HarnessMonitorBackdropMode.none {
      backdropModeRawValue = HarnessMonitorBackdropMode.window.rawValue
    }
    updateRecents(with: background)
  }

  private func updateRecents(with background: HarnessMonitorBackgroundSelection) {
    recentStorageValues = PreferencesBackgroundGalleryRecents.updatedStorageValues(
      recentStorageValues,
      with: background,
      maxItems: Self.maxRecents
    )
  }
}

private struct PreferencesBackgroundTile: View {
  let background: HarnessMonitorBackgroundSelection
  let isSelected: Bool
  let previewHeight: CGFloat
  let select: () -> Void
  @State private var loadedImage: Image?

  private static let selectionRingWidth: CGFloat = 3

  private var outerShape: RoundedRectangle {
    RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusLG, style: .continuous)
  }

  init(
    background: HarnessMonitorBackgroundSelection,
    isSelected: Bool,
    previewHeight: CGFloat,
    select: @escaping () -> Void
  ) {
    self.background = background
    self.isSelected = isSelected
    self.previewHeight = previewHeight
    self.select = select
  }

  var body: some View {
    Button(action: select) {
      ZStack(alignment: .topTrailing) {
        previewContent
          .frame(maxWidth: .infinity)
          .frame(height: isSelected ? previewHeight - 2 * Self.selectionRingWidth : previewHeight)
          .clipped()
          .clipShape(
            RoundedRectangle(
              cornerRadius: isSelected
                ? HarnessMonitorTheme.cornerRadiusLG - Self.selectionRingWidth
                : HarnessMonitorTheme.cornerRadiusLG,
              style: .continuous
            )
          )
          .padding(isSelected ? Self.selectionRingWidth : 0)

        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
          .font(.system(size: 18, weight: .semibold))
          .foregroundStyle(isSelected ? HarnessMonitorTheme.accent : .white.opacity(0.88))
          .padding(HarnessMonitorTheme.spacingSM)
          .shadow(radius: 8, y: 2)
          .accessibilityHidden(true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .frame(height: previewHeight)
      .background {
        outerShape
          .fill(isSelected ? HarnessMonitorTheme.accent : Color.clear)
      }
      .clipShape(outerShape)
      .overlay {
        outerShape
          .strokeBorder(
            isSelected ? Color.clear : HarnessMonitorTheme.controlBorder.opacity(0.55),
            lineWidth: isSelected ? 0 : 1
          )
      }
      .contentShape(outerShape)
    }
    .harnessInteractiveCardButtonStyle(
      cornerRadius: HarnessMonitorTheme.cornerRadiusLG,
      tint: isSelected ? HarnessMonitorTheme.accent : nil
    )
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(background.label)
    .accessibilityValue(isSelected ? "selected" : background.subtitle)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .accessibilityIdentifier(
      HarnessMonitorAccessibility.preferencesBackgroundTile(background.accessibilityKey)
    )
    .task(id: background.storageValue) {
      loadedImage = nil
      guard let cgImage = await BackgroundThumbnailCache.shared.thumbnail(for: background) else {
        return
      }
      loadedImage = Image(decorative: cgImage, scale: 1.0)
    }
  }

  @ViewBuilder private var previewContent: some View {
    if let loadedImage {
      loadedImage
        .resizable()
        .interpolation(.high)
        .aspectRatio(contentMode: .fill)
        .accessibilityHidden(true)
    } else {
      Color.secondary.opacity(0.08)
        .overlay {
          HarnessMonitorSpinner(size: 16)
        }
        .accessibilityHidden(true)
    }
  }
}
