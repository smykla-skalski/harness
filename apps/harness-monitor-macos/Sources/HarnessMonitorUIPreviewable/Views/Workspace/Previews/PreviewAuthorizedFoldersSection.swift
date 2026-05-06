import AppKit
import HarnessMonitorKit
import SwiftUI

#Preview("Authorized Folders Section - Empty") {
  AuthorizedFoldersSection(store: PreferencesPreviewSupport.makeStore())
    .frame(width: 720)
}
