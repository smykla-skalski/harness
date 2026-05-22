import HarnessMonitorKit
import SwiftUI

/// SwiftUI view that resolves and displays a downsampled GitHub avatar
/// for the given login through [`DependencyUpdateAvatarCache`].
///
/// Renders a circular avatar of `size × size` points; while the cache
/// resolves the image, shows a neutral secondary-colored circle so the
/// gutter still claims its space (no layout jump on load completion).
///
/// Bounded to the cache via `.task(id: login)`: when the row recycles
/// onto a different login the previous fetch is cancelled and the new
/// avatar gets requested without a stale flash.
struct AvatarImageView: View {
  let login: String
  let size: CGFloat

  @State private var image: NSImage?
  @Environment(\.displayScale)
  private var displayScale

  var body: some View {
    Group {
      if let image {
        Image(nsImage: image)
          .resizable()
          .scaledToFill()
      } else {
        Circle()
          .fill(Color.secondary.opacity(0.18))
      }
    }
    .frame(width: size, height: size)
    .clipShape(Circle())
    .accessibilityLabel(Text("Avatar for \(login)"))
    .task(id: login) {
      let pixel = max(size * max(displayScale, 1), 32)
      guard
        let url = URL(string: "https://github.com/\(login).png?size=\(Int(pixel))")
      else {
        return
      }
      let resolved = await DependencyUpdateAvatarCache.shared.avatar(
        for: url,
        targetPixel: pixel
      )
      if !Task.isCancelled {
        image = resolved
      }
    }
  }
}
