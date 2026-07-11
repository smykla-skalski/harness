import HarnessMonitorKit
import SwiftUI

struct SettingsTaskBoardLaneAppearanceSection: View {
  @AppStorage(TaskBoardLaneAppearancePreferences.storageKey)
  private var rawValue = TaskBoardLaneAppearancePreferences.emptyRawValue
  @Environment(\.fontScale)
  private var fontScale
  @State private var presentedLane: TaskBoardInboxLane?

  private var appearance: TaskBoardLaneAppearance {
    TaskBoardLaneAppearance(rawValue: rawValue)
  }

  private var laneTitleFont: Font {
    HarnessMonitorTextSize.scaledFont(.body.weight(.medium), by: fontScale)
  }

  private var laneIndicatorFont: Font {
    HarnessMonitorTextSize.scaledFont(.caption.weight(.semibold), by: fontScale)
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
      laneIndicator(for: lane)

      Text(lane.title)
        .font(laneTitleFont)

      Spacer(minLength: HarnessMonitorTheme.spacingMD)

      Button("Customize") {
        presentedLane = lane
      }
      .help("Configure \(lane.title) appearance")
      .accessibilityLabel("Configure \(lane.title) appearance")
    }
    .padding(.vertical, HarnessMonitorTheme.spacingXS)
    .popover(isPresented: presentedBinding(for: lane), arrowEdge: .trailing) {
      SettingsTaskBoardLaneAppearancePopover(lane: lane, rawValue: $rawValue)
    }
  }

  private func laneIndicator(for lane: TaskBoardInboxLane) -> some View {
    ZStack {
      if let symbolName = appearance.symbolName(for: lane) {
        Image(systemName: symbolName)
          .font(laneIndicatorFont)
          .foregroundStyle(.white)
      }
    }
    .frame(width: 58, height: 30)
    .background(appearance.color(for: lane), in: .capsule)
    .overlay {
      Capsule(style: .continuous)
        .strokeBorder(.white.opacity(0.18), lineWidth: 1)
    }
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
  @Environment(\.fontScale)
  private var fontScale

  private static let symbolColumns = Array(
    repeating: GridItem(.flexible(minimum: 44), spacing: HarnessMonitorTheme.spacingXS),
    count: 6
  )

  private var appearance: TaskBoardLaneAppearance {
    TaskBoardLaneAppearance(rawValue: rawValue)
  }

  private var headerFont: Font {
    HarnessMonitorTextSize.scaledFont(.headline.weight(.semibold), by: fontScale)
  }

  private var sectionTitleFont: Font {
    HarnessMonitorTextSize.scaledFont(.caption.weight(.semibold), by: fontScale)
  }

  private var symbolFont: Font {
    HarnessMonitorTextSize.scaledFont(.title3.weight(.semibold), by: fontScale)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
      header
      Divider()
      colorSection
      Divider()
      symbolSection
      Divider()
      cardsSection
    }
    .padding(HarnessMonitorTheme.spacingMD)
    .frame(width: 360, alignment: .topLeading)
  }

  private var header: some View {
    HStack(spacing: HarnessMonitorTheme.spacingSM) {
      Text(lane.title)
        .font(headerFont)
      Spacer(minLength: HarnessMonitorTheme.spacingMD)
      Button {
        rawValue = TaskBoardLaneAppearancePreferences.resetRawValue(
          for: lane,
          rawValue: rawValue
        )
      } label: {
        Label("Reset", systemImage: "arrow.counterclockwise")
      }
      .buttonStyle(.borderless)
      .disabled(!appearance.hasOverride(for: lane))
    }
  }

  private var colorSection: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      sectionHeader(title: "Color") {
        Button {
          rawValue = TaskBoardLaneAppearancePreferences.resetColorRawValue(
            for: lane,
            rawValue: rawValue
          )
        } label: {
          Label("Reset", systemImage: "arrow.counterclockwise")
        }
        .buttonStyle(.borderless)
        .disabled(!appearance.hasColorOverride(for: lane))
      }

      ColorPicker(selection: colorBinding, supportsOpacity: false) {
        EmptyView()
      }
      .labelsHidden()
    }
  }

  private var symbolSection: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      sectionHeader(title: "Symbol") {
        HStack(spacing: HarnessMonitorTheme.spacingSM) {
          Button {
            rawValue = TaskBoardLaneAppearancePreferences.settingSymbolVisibility(
              false,
              for: lane,
              rawValue: rawValue
            )
          } label: {
            Label("Clear", systemImage: "slash.circle")
          }
          .disabled(appearance.hidesSymbol(for: lane))

          Button {
            rawValue = TaskBoardLaneAppearancePreferences.resetSymbolRawValue(
              for: lane,
              rawValue: rawValue
            )
          } label: {
            Label("Reset", systemImage: "arrow.counterclockwise")
          }
          .disabled(!appearance.hasSymbolOverride(for: lane))
        }
        .buttonStyle(.borderless)
      }

      LazyVGrid(
        columns: Self.symbolColumns,
        alignment: .leading,
        spacing: HarnessMonitorTheme.spacingXS
      ) {
        ForEach(Self.symbolOptions(for: lane), id: \.self) { symbolName in
          symbolButton(symbolName)
        }
      }
    }
  }

  private var cardsSection: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      sectionHeader(title: "Cards") {
        Button {
          rawValue = TaskBoardLaneAppearancePreferences.settingPriorityBadgeVisibility(
            true,
            for: lane,
            rawValue: rawValue
          )
        } label: {
          Label("Reset", systemImage: "arrow.counterclockwise")
        }
        .buttonStyle(.borderless)
        .disabled(!appearance.hasPriorityBadgeOverride(for: lane))
      }

      Toggle("Priority Badge", isOn: priorityBadgeBinding)
    }
  }

  private func sectionHeader<Actions: View>(
    title: String,
    @ViewBuilder actions: () -> Actions
  ) -> some View {
    HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingSM) {
      Text(title)
        .font(sectionTitleFont)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      Spacer(minLength: HarnessMonitorTheme.spacingMD)
      actions()
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
        .font(symbolFont)
        .foregroundStyle(symbolForegroundStyle(for: symbolName))
        .frame(maxWidth: .infinity, minHeight: 46)
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

  private var priorityBadgeBinding: Binding<Bool> {
    Binding(
      get: { appearance.showsPriorityBadge(for: lane) },
      set: { isVisible in
        rawValue = TaskBoardLaneAppearancePreferences.settingPriorityBadgeVisibility(
          isVisible,
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
    "gearshape",
    "wand.and.stars",
    "checkmark.circle",
    "xmark.circle",
    "clock",
    "calendar",
    "folder",
    "archivebox",
    "tray",
    "tray.full",
    "bell",
    "bell.badge",
    "key",
    "lock",
    "lock.shield",
    "paperplane",
    "paperclip",
    "link",
    "bookmark",
    "play.circle",
    "pause.circle",
    "stop.circle",
    "terminal",
    "curlybraces",
    "flame",
    "star",
    "questionmark.circle",
    "ellipsis.circle",
    "target",
    "network",
    "server.rack",
    "list.bullet.rectangle",
  ]
}
