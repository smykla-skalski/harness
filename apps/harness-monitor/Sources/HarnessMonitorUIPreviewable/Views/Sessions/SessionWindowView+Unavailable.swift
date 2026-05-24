import SwiftUI

extension SessionWindowView {
  var isUnknownSession: Bool {
    didLoadSnapshot && snapshot == nil && summary == nil
  }

  var unknownSessionContent: some View {
    SessionWindowUnavailableView(
      sessionID: token.sessionID,
      closeWindow: {
        dismiss()
      },
      openRecents: {
        openWindow.openHarnessDashboardWindow()
        dismiss()
      }
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
  }
}
