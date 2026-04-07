import SwiftUI

struct PreferencesBackgroundGallery: View {
  @Binding var selection: String
  @Binding var backdropModeRawValue: String
  let selectedBackground: HarnessMonitorBackgroundSelection
  let collection: BackgroundCollection
  @ScaledMetric(relativeTo: .body) private var previewHeight = 96.0

  private var options: [HarnessMonitorBackgroundSelection] {
    switch collection {
    case .featured: HarnessMonitorBackgroundSelection.bundledLibrary
    case .native: HarnessMonitorBackgroundSelection.systemLibrary
    }
  }

  private let columns = [
    GridItem(.adaptive(minimum: 180, maximum: 220), spacing: HarnessMonitorTheme.spacingMD)
  ]

  var body: some View {
    if options.isEmpty {
      ContentUnavailableView(
        "No wallpapers found",
        systemImage: "photo",
        description: Text("macOS wallpapers were not found on this Mac")
      )
    } else {
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
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier(HarnessMonitorAccessibility.preferencesBackgroundGallery)
    }
  }

  private func select(_ background: HarnessMonitorBackgroundSelection) {
    selection = background.storageValue
    if HarnessMonitorBackdropMode(rawValue: backdropModeRawValue) == HarnessMonitorBackdropMode.none {
      backdropModeRawValue = HarnessMonitorBackdropMode.window.rawValue
    }
  }
}

private struct PreferencesBackgroundTile: View {
  let background: HarnessMonitorBackgroundSelection
  let isSelected: Bool
  let previewHeight: CGFloat
  let select: () -> Void

  var body: some View {
    Button(action: select) {
      ZStack(alignment: .topTrailing) {
        previewImage

        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
          .font(.system(size: 18, weight: .semibold))
          .foregroundStyle(isSelected ? HarnessMonitorTheme.accent : .white.opacity(0.88))
          .padding(HarnessMonitorTheme.spacingSM)
          .shadow(radius: 8, y: 2)
          .accessibilityHidden(true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .clipShape(
        RoundedRectangle(
          cornerRadius: HarnessMonitorTheme.cornerRadiusLG,
          style: .continuous
        )
      )
      .overlay {
        RoundedRectangle(
          cornerRadius: HarnessMonitorTheme.cornerRadiusLG,
          style: .continuous
        )
        .strokeBorder(
          isSelected ? HarnessMonitorTheme.accent.opacity(0.5) : HarnessMonitorTheme.controlBorder.opacity(0.55),
          lineWidth: isSelected ? 1.5 : 1
        )
      }
      .contentShape(
        RoundedRectangle(
          cornerRadius: HarnessMonitorTheme.cornerRadiusLG,
          style: .continuous
        )
      )
    }
    .buttonStyle(.plain)
    .harnessInteractiveCardButtonStyle(
      cornerRadius: HarnessMonitorTheme.cornerRadiusLG,
      tint: isSelected ? HarnessMonitorTheme.accent : nil
    )
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(background.label)
    .accessibilityValue(isSelected ? "selected" : background.subtitle)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .accessibilityIdentifier(HarnessMonitorAccessibility.preferencesBackgroundTile(background.accessibilityKey))
  }

  @ViewBuilder
  private var previewImage: some View {
    if let image = HarnessMonitorUIAssets.backgroundImage(for: background) {
      image
        .resizable()
        .interpolation(.high)
        .aspectRatio(contentMode: .fill)
        .frame(maxWidth: .infinity)
        .frame(height: previewHeight)
        .accessibilityHidden(true)
    } else {
      Color.secondary.opacity(0.12)
        .frame(maxWidth: .infinity)
        .frame(height: previewHeight)
        .overlay {
          Image(systemName: "photo")
            .font(.system(size: 20, weight: .medium))
            .foregroundStyle(.secondary)
        }
        .accessibilityHidden(true)
    }
  }
}
