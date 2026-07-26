import HarnessMonitorKit
import SwiftUI

private struct PreviewTaskBoardLaneColorPickerHost: View {
  let lane: TaskBoardInboxLane
  @State private var rawValue: String

  init(
    lane: TaskBoardInboxLane,
    rawValue: String = TaskBoardLaneAppearancePreferences.emptyRawValue
  ) {
    self.lane = lane
    _rawValue = State(initialValue: rawValue)
  }

  var body: some View {
    SettingsTaskBoardLaneColorPicker(lane: lane, rawValue: $rawValue)
      .padding(HarnessMonitorTheme.spacingMD)
      .frame(width: 360)
  }
}

#Preview("Task Board Lane Color Picker") {
  PreviewTaskBoardLaneColorPickerHost(lane: .inProgress)
}

#Preview("Task Board Lane Color Picker - Custom") {
  PreviewTaskBoardLaneColorPickerHost(
    lane: .inProgress,
    rawValue: TaskBoardLaneAppearancePreferences.settingCustomColor(
      Color(hue: 0.55, saturation: 0.72, brightness: 0.9),
      for: .inProgress,
      rawValue: TaskBoardLaneAppearancePreferences.emptyRawValue
    )
  )
}
