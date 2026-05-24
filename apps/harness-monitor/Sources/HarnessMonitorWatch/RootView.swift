import SwiftUI

struct RootView: View {
  var body: some View {
    VStack(spacing: 8) {
      Image(systemName: "rectangle.stack")
        .font(.system(size: 28))
        .foregroundStyle(.tint)
      Text("View pull requests on your Mac.")
        .font(.body)
        .multilineTextAlignment(.center)
      Text("Add the Needs-Me complication to your watch face.")
        .font(.caption2)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .padding()
  }
}

#Preview {
  RootView()
}
