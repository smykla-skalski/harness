import HarnessMonitorKit
import SwiftUI

struct SettingsTaskBoardLaneAppearanceSection: View {
  @AppStorage(TaskBoardLaneAppearancePreferences.storageKey)
  private var rawValue = TaskBoardLaneAppearancePreferences.emptyRawValue
  @State private var presentedLane: TaskBoardInboxLane?

  private var appearance: TaskBoardLaneAppearance {
    TaskBoardLaneAppearance(rawValue: rawValue)
  }

  var body: some View {
    Section {
      ForEach(TaskBoardInboxLane.allCases) { lane in
        laneRow(lane)
      }
      HStack {
        Spacer(minLength: 0)
        Button {
          rawValue = TaskBoardLaneAppearancePreferences.emptyRawValue
        } label: {
          Label("Reset All", systemImage: "arrow.counterclockwise")
        }
        .disabled(rawValue == TaskBoardLaneAppearancePreferences.emptyRawValue)
      }
    } header: {
      Text("Lane Appearance")
        .harnessNativeFormSectionHeader()
    }
  }

  private func laneRow(_ lane: TaskBoardInboxLane) -> some View {
    HStack(spacing: HarnessMonitorTheme.spacingMD) {
      Button {
        presentedLane = lane
      } label: {
        symbolPreview(for: lane)
      }
      .harnessPlainButtonStyle()
      .help("Configure \(lane.title) appearance")
      .accessibilityLabel("Configure \(lane.title) appearance")

      Text(lane.title)
        .font(.body.weight(.medium))

      Spacer(minLength: HarnessMonitorTheme.spacingMD)

      Button {
        presentedLane = lane
      } label: {
        colorPreview(for: lane)
      }
      .harnessPlainButtonStyle()
      .help("Configure \(lane.title) top bar color")
      .accessibilityLabel("Configure \(lane.title) top bar color")
    }
    .padding(.vertical, HarnessMonitorTheme.spacingXS)
    .popover(isPresented: presentedBinding(for: lane), arrowEdge: .trailing) {
      SettingsTaskBoardLaneAppearancePopover(lane: lane, rawValue: $rawValue)
    }
  }

  private func symbolPreview(for lane: TaskBoardInboxLane) -> some View {
    ZStack {
      RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusSM, style: .continuous)
        .fill(appearance.color(for: lane).opacity(0.14))
      RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusSM, style: .continuous)
        .strokeBorder(appearance.color(for: lane).opacity(0.32), lineWidth: 1)
      if let symbolName = appearance.symbolName(for: lane) {
        Image(systemName: symbolName)
          .font(.body.weight(.semibold))
          .foregroundStyle(appearance.color(for: lane))
      } else {
        Image(systemName: "slash.circle")
          .font(.body.weight(.semibold))
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
    }
    .frame(width: 34, height: 34)
    .accessibilityHidden(true)
  }

  private func colorPreview(for lane: TaskBoardInboxLane) -> some View {
    Capsule(style: .continuous)
      .fill(appearance.color(for: lane))
      .frame(width: 54, height: 18)
      .overlay {
        Capsule(style: .continuous)
          .strokeBorder(HarnessMonitorTheme.controlBorder.opacity(0.54), lineWidth: 1)
      }
      .accessibilityHidden(true)
  }

  private func presentedBinding(for lane: TaskBoardInboxLane) -> Binding<Bool> {
    Binding(
      get: { presentedLane == lane },
      set: { isPresented in
        if !isPresented, presentedLane == lane {
          presentedLane = nil
        }
      }
    )
  }
}

private struct SettingsTaskBoardLaneAppearancePopover: View {
  let lane: TaskBoardInboxLane
  @Binding var rawValue: String

  private static let symbolColumns = Array(
    repeating: GridItem(.fixed(36), spacing: HarnessMonitorTheme.spacingXS),
    count: 6
  )

  private var appearance: TaskBoardLaneAppearance {
    TaskBoardLaneAppearance(rawValue: rawValue)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
      header
      symbolPicker
      Divider()
      colorPicker
    }
    .padding(HarnessMonitorTheme.spacingMD)
    .frame(width: 320, alignment: .topLeading)
  }

  private var header: some View {
    HStack(spacing: HarnessMonitorTheme.spacingSM) {
      Text(lane.title)
        .font(.headline.weight(.semibold))
      Spacer(minLength: HarnessMonitorTheme.spacingMD)
      Button {
        rawValue = TaskBoardLaneAppearancePreferences.resetRawValue(
          for: lane,
          rawValue: rawValue
        )
      } label: {
        Label("Reset Lane", systemImage: "arrow.counterclockwise")
      }
      .buttonStyle(.borderless)
      .disabled(!appearance.hasOverride(for: lane))
    }
  }

  private var symbolPicker: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Text("Symbol")
        .font(.caption.weight(.semibold))
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      LazyVGrid(
        columns: Self.symbolColumns,
        alignment: .leading,
        spacing: HarnessMonitorTheme.spacingXS
      ) {
        ForEach(Self.symbolOptions(for: lane), id: \.self) { symbolName in
          symbolButton(symbolName)
        }
      }
      HStack(spacing: HarnessMonitorTheme.spacingSM) {
        Button {
          rawValue = TaskBoardLaneAppearancePreferences.settingSymbolVisibility(
            false,
            for: lane,
            rawValue: rawValue
          )
        } label: {
          Label("Remove Symbol", systemImage: "slash.circle")
        }
        Button {
          rawValue = TaskBoardLaneAppearancePreferences.resetSymbolRawValue(
            for: lane,
            rawValue: rawValue
          )
        } label: {
          Label("Reset Symbol", systemImage: "arrow.counterclockwise")
        }
        .disabled(!appearance.hasSymbolOverride(for: lane))
      }
      .buttonStyle(.borderless)
    }
  }

  private var colorPicker: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Text("Top Bar Color")
        .font(.caption.weight(.semibold))
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      ColorPicker("Color", selection: colorBinding, supportsOpacity: false)
      HStack(spacing: HarnessMonitorTheme.spacingSM) {
        colorSwatch
        Button {
          rawValue = TaskBoardLaneAppearancePreferences.resetColorRawValue(
            for: lane,
            rawValue: rawValue
          )
        } label: {
          Label("Reset Color", systemImage: "arrow.counterclockwise")
        }
        .buttonStyle(.borderless)
        .disabled(!appearance.hasColorOverride(for: lane))
      }
    }
  }

  private func symbolButton(_ symbolName: String) -> some View {
    Button {
      rawValue = TaskBoardLaneAppearancePreferences.settingSymbolName(
        symbolName,
        for: lane,
        rawValue: rawValue
      )
    } label: {
      Image(systemName: symbolName)
        .font(.body.weight(.semibold))
        .foregroundStyle(symbolForegroundStyle(for: symbolName))
        .frame(width: 32, height: 32)
        .background(symbolButtonBackground(for: symbolName), in: .rect(cornerRadius: 8))
        .overlay {
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(appearance.color(for: lane).opacity(0.28), lineWidth: 1)
        }
    }
    .harnessPlainButtonStyle()
    .help(symbolName)
    .accessibilityLabel("Use \(symbolName) symbol")
  }

  private func symbolButtonBackground(for symbolName: String) -> Color {
    symbolName == appearance.symbolName(for: lane)
      ? appearance.color(for: lane)
      : appearance.color(for: lane).opacity(0.12)
  }

  private func symbolForegroundStyle(for symbolName: String) -> Color {
    symbolName == appearance.symbolName(for: lane) ? .white : appearance.color(for: lane)
  }

  private var colorSwatch: some View {
    RoundedRectangle(cornerRadius: 8, style: .continuous)
      .fill(appearance.color(for: lane))
      .frame(width: 42, height: 24)
      .overlay {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .strokeBorder(HarnessMonitorTheme.controlBorder.opacity(0.54), lineWidth: 1)
      }
      .accessibilityHidden(true)
  }

  private var colorBinding: Binding<Color> {
    Binding(
      get: { appearance.color(for: lane) },
      set: { color in
        rawValue = TaskBoardLaneAppearancePreferences.settingCustomColor(
          color,
          for: lane,
          rawValue: rawValue
        )
      }
    )
  }

  private static func symbolOptions(for lane: TaskBoardInboxLane) -> [String] {
    var seen = Set<String>()
    return ([lane.systemImage] + TaskBoardInboxLane.allCases.map(\.systemImage) + extraSymbols)
      .filter { seen.insert($0).inserted }
  }

  private static let extraSymbols = [
    "flag",
    "tag",
    "bolt",
    "hourglass",
    "hammer",
    "wrench.and.screwdriver",
    "person.2",
    "eye",
    "shippingbox",
    "doc.text",
    "pencil.and.list.clipboard",
    "arrow.triangle.pull",
    "number.circle",
    "smallcircle.filled.circle",
  ]
}
