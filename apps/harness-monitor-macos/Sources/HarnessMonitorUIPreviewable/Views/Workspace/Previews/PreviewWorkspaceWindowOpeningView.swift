import SwiftUI

#Preview("Workspace Opening - Light") {
  WorkspaceWindowOpeningView()
    .frame(width: 1_020, height: 680)
    .preferredColorScheme(.light)
}

#Preview("Workspace Opening - Dark") {
  WorkspaceWindowOpeningView()
    .frame(width: 1_020, height: 680)
    .preferredColorScheme(.dark)
}
