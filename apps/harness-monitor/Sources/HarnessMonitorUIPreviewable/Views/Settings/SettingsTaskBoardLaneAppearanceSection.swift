import HarnessMonitorKit
import SwiftUI

struct SettingsTaskBoardLaneAppearanceSection: View {
  @AppStorage(TaskBoardLaneAppearancePreferences.storageKey)
  private var rawValue = TaskBoardLaneAppearancePreferences.emptyRawValue

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
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      HStack(spacing: HarnessMonitorTheme.spacingSM) {
        laneSymbolPreview(lane)
        Text(lane.title)
          .font(.body.weight(.medium))
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
      HStack(spacing: HarnessMonitorTheme.spacingMD) {
        Picker("Top Bar", selection: colorBinding(for: lane)) {
          ForEach(TaskBoardLaneColorToken.allCases) { colorToken in
            HStack(spacing: HarnessMonitorTheme.spacingXS) {
              Circle()
                .fill(colorToken.color)
                .frame(width: 10, height: 10)
              Text(colorToken.title)
            }
            .tag(colorToken)
          }
        }
        .pickerStyle(.menu)
        Toggle("Show Symbol", isOn: symbolVisibilityBinding(for: lane))
          .toggleStyle(.checkbox)
        TextField(
          "Symbol",
          text: symbolBinding(for: lane),
          prompt: Text(TaskBoardLaneAppearancePreferences.defaultSymbolName(for: lane))
        )
        .textFieldStyle(.roundedBorder)
        .frame(maxWidth: 240)
        .disabled(appearance.hidesSymbol(for: lane))
      }
    }
    .padding(.vertical, HarnessMonitorTheme.spacingXS)
  }

  @ViewBuilder
  private func laneSymbolPreview(_ lane: TaskBoardInboxLane) -> some View {
    if let symbolName = appearance.symbolName(for: lane) {
      Image(systemName: symbolName)
        .foregroundStyle(appearance.color(for: lane))
        .frame(width: 22)
        .accessibilityHidden(true)
    } else {
      Color.clear
        .frame(width: 22, height: 22)
        .accessibilityHidden(true)
    }
  }

  private func colorBinding(for lane: TaskBoardInboxLane) -> Binding<TaskBoardLaneColorToken> {
    Binding(
      get: { appearance.colorToken(for: lane) },
      set: { colorToken in
        rawValue = TaskBoardLaneAppearancePreferences.settingColorToken(
          colorToken,
          for: lane,
          rawValue: rawValue
        )
      }
    )
  }

  private func symbolBinding(for lane: TaskBoardInboxLane) -> Binding<String> {
    Binding(
      get: { TaskBoardLaneAppearancePreferences.overrides(from: rawValue)[lane]?.symbolName ?? "" },
      set: { symbolName in
        rawValue = TaskBoardLaneAppearancePreferences.settingSymbolName(
          symbolName,
          for: lane,
          rawValue: rawValue
        )
      }
    )
  }

  private func symbolVisibilityBinding(for lane: TaskBoardInboxLane) -> Binding<Bool> {
    Binding(
      get: { !appearance.hidesSymbol(for: lane) },
      set: { isVisible in
        rawValue = TaskBoardLaneAppearancePreferences.settingSymbolVisibility(
          isVisible,
          for: lane,
          rawValue: rawValue
        )
      }
    )
  }
}
