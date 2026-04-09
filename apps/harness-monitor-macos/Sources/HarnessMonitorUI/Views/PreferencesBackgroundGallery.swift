import SwiftUI

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
    !recentStorageValues.isEmpty
  }

  private var options: [HarnessMonitorBackgroundSelection] {
    switch collection {
    case .featured: HarnessMonitorBackgroundSelection.bundledLibrary
    case .native: HarnessMonitorBackgroundSelection.systemLibrary
    }
  }

  private var recentItems: [HarnessMonitorBackgroundSelection] {
    let stored =
      recentStorageValues.isEmpty
      ? []
      : recentStorageValues.split(separator: "|").map(String.init)
    var items = [selectedBackground]
    for value in stored where value != selectedBackground.storageValue {
      items.append(HarnessMonitorBackgroundSelection.decode(value))
    }
    return Array(items.prefix(Self.maxRecents))
  }

  private let columns = [
    GridItem(.adaptive(minimum: 180, maximum: 220), spacing: HarnessMonitorTheme.spacingMD)
  ]

  var body: some View {
    if isBackdropDisabled {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingLG) {
        if hasStoredRecents {
          recentBackgroundsRow
            .saturation(0)
            .allowsHitTesting(false)
        }

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
        recentBackgroundsRow

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
      .task(id: collection) {
        await BackgroundThumbnailCache.shared.prefetch(options)
      }
      .task(id: recentStorageValues) {
        await BackgroundThumbnailCache.shared.prefetch(recentItems)
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
    var stored =
      recentStorageValues.isEmpty
      ? []
      : recentStorageValues.split(separator: "|").map(String.init)
    stored.removeAll { $0 == background.storageValue }
    stored.insert(background.storageValue, at: 0)
    stored = Array(stored.prefix(Self.maxRecents))
    recentStorageValues = stored.joined(separator: "|")
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
      let size = NSSize(width: cgImage.width, height: cgImage.height)
      loadedImage = Image(nsImage: NSImage(cgImage: cgImage, size: size))
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
