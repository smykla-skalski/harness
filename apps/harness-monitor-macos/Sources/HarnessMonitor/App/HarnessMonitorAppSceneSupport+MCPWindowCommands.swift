import HarnessMonitorKit
import HarnessMonitorUIPreviewable

enum HarnessMonitorMCPWindowCommandDescriptors {
  static let all = [
    HarnessMonitorMCPWindowCommandDescriptor(
      identifier: HarnessMonitorAccessibility.windowMenuMainItem,
      label: WindowMenuCommands.mainTitle,
      hint: "Open the recent sessions window.",
      windowID: HarnessMonitorWindowID.openRecent
    )
  ]
}
