import AppKit
import ColorSelector
import HarnessMonitorKit
import SwiftUI

/// Lane color editing for the appearance popover: the theme presets first,
/// then a hue/saturation surface for anything they do not cover. Both stay
/// inside the popover on purpose. The native `ColorPicker` this replaced
/// opened the shared `NSColorPanel` in its own floating window, which went on
/// floating above everything after the popover that spawned it had closed.
struct SettingsTaskBoardLaneColorPicker: View {
  let lane: TaskBoardInboxLane
  @Binding var rawValue: String

  @Environment(\.fontScale)
  private var fontScale

  /// Drives the surface while the user is dragging it. A stored sRGB triple
  /// cannot round-trip hue once saturation or brightness reaches zero, so
  /// re-deriving components from the lane on every change would snap the
  /// marker back to red the moment a drag crossed black or grey. `nil` means
  /// the lane's own color is the truth.
  @State private var draft: TaskBoardLaneColorComponents?

  private static let swatchColumns = Array(
    repeating: GridItem(.flexible(minimum: 44), spacing: HarnessMonitorTheme.spacingXS),
    count: 6
  )

  private var appearance: TaskBoardLaneAppearance {
    TaskBoardLaneAppearance(rawValue: rawValue)
  }

  private var components: TaskBoardLaneColorComponents {
    draft ?? TaskBoardLaneColorComponents(appearance.color(for: lane))
  }

  /// No preset is current once a custom color wins, even though the lane still
  /// carries whichever token it had before.
  private var selectedToken: TaskBoardLaneColorToken? {
    appearance.customColor(for: lane) == nil ? appearance.colorToken(for: lane) : nil
  }

  private var captionFont: Font {
    HarnessMonitorTextSize.scaledFont(.caption, by: fontScale)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      LazyVGrid(
        columns: Self.swatchColumns,
        alignment: .leading,
        spacing: HarnessMonitorTheme.spacingXS
      ) {
        ForEach(TaskBoardLaneColorToken.allCases) { token in
          swatch(token)
        }
      }

      Text("Custom")
        .font(captionFont)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)

      Saturation(
        saturation: binding(\.saturation),
        brightness: binding(\.brightness),
        hue: components.hue
      )
      .frame(height: 96)
      .accessibilityLabel("\(lane.title) custom color saturation and brightness")

      HueSlider(hue: binding(\.hue))
        .accessibilityLabel("\(lane.title) custom color hue")
    }
    .environment(\.cornerSize, 8)
    .environment(\.pointSize, CGSize(width: 14, height: 14))
    .onChange(of: rawValue) { _, updated in
      // A preset click, either Reset, or another window editing the same
      // defaults all drop the custom color, which leaves the drag components
      // describing a color the lane no longer has.
      if TaskBoardLaneAppearance(rawValue: updated).customColor(for: lane) == nil {
        draft = nil
      }
    }
  }

  private func swatch(_ token: TaskBoardLaneColorToken) -> some View {
    let isSelected = token == selectedToken
    return Button {
      draft = nil
      rawValue = TaskBoardLaneAppearancePreferences.settingColorToken(
        token,
        for: lane,
        rawValue: rawValue
      )
    } label: {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(token.color)
        .frame(maxWidth: .infinity, minHeight: 28)
        .overlay {
          if isSelected {
            Image(systemName: "checkmark")
              .font(HarnessMonitorTextSize.scaledFont(.body.weight(.bold), by: fontScale))
              .foregroundStyle(.white)
          }
        }
        .overlay {
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(
              isSelected
                ? HarnessMonitorTheme.ink.opacity(0.55) : HarnessMonitorTheme.ink.opacity(0.18),
              lineWidth: isSelected ? 2 : 1
            )
        }
    }
    .harnessPlainButtonStyle()
    .help(token.title)
    // The checkmark is the only visible "selected", and it rides on the swatch
    // rather than beside a name, so VoiceOver needs the trait set explicitly.
    .accessibilityLabel(token.title)
    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
  }

  private func binding(
    _ keyPath: WritableKeyPath<TaskBoardLaneColorComponents, CGFloat>
  ) -> Binding<CGFloat> {
    Binding(
      get: { components[keyPath: keyPath] },
      set: { value in
        var updated = components
        updated[keyPath: keyPath] = value
        draft = updated
        rawValue = TaskBoardLaneAppearancePreferences.settingCustomColor(
          updated.color,
          for: lane,
          rawValue: rawValue
        )
      }
    )
  }
}

/// The surface works in HSB while the lane stores RGB, and the conversion is
/// only lossless in one direction.
struct TaskBoardLaneColorComponents: Equatable {
  var hue: CGFloat
  var saturation: CGFloat
  var brightness: CGFloat

  init(hue: CGFloat, saturation: CGFloat, brightness: CGFloat) {
    self.hue = hue
    self.saturation = saturation
    self.brightness = brightness
  }

  init(_ color: Color) {
    // `hueComponent` and friends trap unless the receiver is already in an RGB
    // space, and a lane color can arrive as a named theme asset.
    guard let rgb = NSColor(color).usingColorSpace(.sRGB) else {
      self.init(hue: 0, saturation: 0, brightness: 0)
      return
    }
    self.init(
      hue: rgb.hueComponent,
      saturation: rgb.saturationComponent,
      brightness: rgb.brightnessComponent
    )
  }

  var color: Color {
    Color(hue: hue, saturation: saturation, brightness: brightness)
  }
}
