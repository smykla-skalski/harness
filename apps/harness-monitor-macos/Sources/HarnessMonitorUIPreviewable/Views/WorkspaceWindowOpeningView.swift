import SwiftUI

public struct WorkspaceWindowOpeningView: View {
  public init() {}

  public var body: some View {
    Color.clear
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color(nsColor: .windowBackgroundColor))
      .accessibilityHidden(true)
  }
}

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
