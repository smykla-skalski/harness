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
