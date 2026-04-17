import AppKit

public enum HarnessMonitorClipboard {
  @MainActor
  public static func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }
}
