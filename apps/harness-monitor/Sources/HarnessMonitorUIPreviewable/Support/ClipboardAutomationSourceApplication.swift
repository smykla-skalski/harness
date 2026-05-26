import AppKit
import Foundation

enum ClipboardAutomationSourceApplicationResolver {
  static func current(confidence: String) -> AutomationSourceApplication? {
    guard let app = NSWorkspace.shared.frontmostApplication else {
      return nil
    }
    return AutomationSourceApplication(
      bundleIdentifier: app.bundleIdentifier,
      localizedName: app.localizedName,
      processIdentifier: app.processIdentifier,
      confidence: confidence
    )
  }
}
