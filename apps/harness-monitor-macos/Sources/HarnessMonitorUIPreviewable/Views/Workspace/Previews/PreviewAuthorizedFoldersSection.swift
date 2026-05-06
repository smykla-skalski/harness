import AppKit
import HarnessMonitorKit
import SwiftUI

#Preview("Authorized Folders Section - Empty") {
  AuthorizedFoldersSection(store: SettingsPreviewSupport.makeStore())
    .frame(width: 720)
}
