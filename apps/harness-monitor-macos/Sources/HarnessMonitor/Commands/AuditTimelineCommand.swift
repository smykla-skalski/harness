import HarnessMonitorUIPreviewable
import SwiftUI

/// View-menu command that opens the Supervisor audit timeline. The action is
/// dispatched via the `supervisorAuditTimelineFocus` focused-scene value so
/// the host scene can route to the Supervisor settings pane with any filter
/// the caller wants pre-applied.
struct AuditTimelineCommand: Commands {
  @FocusedValue(\.supervisorAuditTimelineFocus)
  private var auditTimelineFocus

  var body: some Commands {
    CommandGroup(after: .toolbar) {
      Button("Audit Timeline") {
        auditTimelineFocus?.invoke()
      }
      .keyboardShortcut("a", modifiers: [.command, .shift])
      .disabled(auditTimelineFocus == nil)
    }
  }
}
