import AppKit
import HarnessMonitorKit
import SwiftUI

typealias TimelineAvatarImageLoader = (String, URL?, CGFloat) async -> NSImage?

/// SwiftUI view that resolves and displays a downsampled GitHub avatar
/// for the given login through the injected daemon-backed loader.
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
  let avatarURL: URL?
  let size: CGFloat
  let loadImage: TimelineAvatarImageLoader?

  @State private var image: NSImage?
  @Environment(\.displayScale)
  private var displayScale

  init(
    login: String,
    avatarURL: URL? = nil,
    size: CGFloat,
    loadImage: TimelineAvatarImageLoader? = nil
  ) {
    self.login = login
    self.avatarURL = avatarURL
    self.size = size
    self.loadImage = loadImage
  }

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
    .task(id: taskID) {
      let pixel = max(size * max(displayScale, 1), 32)
      image = nil
      guard let loadImage else { return }
      let resolved = await loadImage(login, avatarURL, pixel)
      if !Task.isCancelled {
        image = resolved
      }
    }
  }

  private var taskID: String {
    "\(login)|\(avatarURL?.absoluteString ?? "")"
  }
}
