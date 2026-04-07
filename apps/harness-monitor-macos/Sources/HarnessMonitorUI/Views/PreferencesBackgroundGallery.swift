import SwiftUI

struct PreferencesBackgroundGallery: View {
  @Binding var selection: String
  @Binding var backdropModeRawValue: String
  let selectedBackground: HarnessMonitorBackgroundSelection
  @State private var isSystemWallpapersExpanded = false
  @ScaledMetric(relativeTo: .body) private var previewHeight = 96.0

  private let featuredBackgrounds = HarnessMonitorBackgroundSelection.bundledLibrary
  private let systemBackgrounds = HarnessMonitorBackgroundSelection.systemLibrary
  private let columns = [
    GridItem(.adaptive(minimum: 180, maximum: 220), spacing: HarnessMonitorTheme.spacingMD)
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Text("Background image")
        .font(.headline)

      if !systemBackgrounds.isEmpty {
        VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
          Button(action: toggleSystemWallpapers) {
            HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingSM) {
              Image(systemName: isSystemWallpapersExpanded ? "chevron.down" : "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 12, alignment: .center)
                .padding(.top, 2)
                .accessibilityHidden(true)

              VStack(alignment: .leading, spacing: 2) {
                Text("macOS wallpapers")
                  .font(.subheadline.weight(.semibold))
                Text("Expand to browse the wallpapers bundled with macOS on this Mac")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }

              Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel("macOS wallpapers")
          .accessibilityValue(isSystemWallpapersExpanded ? "expanded" : "collapsed")
          .accessibilityHint("Shows wallpapers bundled with macOS on this Mac")
          .accessibilityIdentifier(HarnessMonitorAccessibility.preferencesSystemBackgroundsDisclosure)

          if isSystemWallpapersExpanded {
            gallerySection(
              title: "macOS wallpapers",
              subtitle: "Read live from /System/Library/Desktop Pictures on this Mac",
              options: systemBackgrounds
            )
            .padding(.leading, HarnessMonitorTheme.spacingLG)
          }
        }
      }

      gallerySection(
        title: "Featured collection",
        subtitle: "Curated backgrounds bundled with Harness Monitor",
        options: featuredBackgrounds
      )
    }
    .padding(.vertical, HarnessMonitorTheme.spacingXS)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.preferencesBackgroundGallery)
    .onAppear(perform: expandSystemWallpapersIfNeeded)
    .onChange(of: selectedBackground.storageValue) { _, _ in
      expandSystemWallpapersIfNeeded()
    }
  }

  @ViewBuilder
  private func gallerySection(
    title: String,
    subtitle: String,
    options: [HarnessMonitorBackgroundSelection]
  ) -> some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.subheadline.weight(.semibold))
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
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
  }

  private func select(_ background: HarnessMonitorBackgroundSelection) {
    selection = background.storageValue
    if HarnessMonitorBackdropMode(rawValue: backdropModeRawValue) == HarnessMonitorBackdropMode.none {
      backdropModeRawValue = HarnessMonitorBackdropMode.window.rawValue
    }
  }

  private func toggleSystemWallpapers() {
    withAnimation(.easeInOut(duration: 0.18)) {
      isSystemWallpapersExpanded.toggle()
    }
  }

  private func expandSystemWallpapersIfNeeded() {
    guard case .system = selectedBackground.source else {
      return
    }

    isSystemWallpapersExpanded = true
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
      .padding(HarnessMonitorTheme.spacingSM)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background {
        RoundedRectangle(
          cornerRadius: HarnessMonitorTheme.cornerRadiusLG,
          style: .continuous
        )
        .fill(isSelected ? HarnessMonitorTheme.accent.opacity(0.12) : Color.secondary.opacity(0.05))
      }
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
        .clipShape(
          RoundedRectangle(
            cornerRadius: HarnessMonitorTheme.cornerRadiusMD,
            style: .continuous
          )
        )
        .accessibilityHidden(true)
    } else {
      RoundedRectangle(
        cornerRadius: HarnessMonitorTheme.cornerRadiusMD,
        style: .continuous
      )
      .fill(Color.secondary.opacity(0.12))
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
