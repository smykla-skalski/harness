import AppKit
import Foundation

extension HarnessMonitorStore {
  public func reviewAvatarImage(
    login: String,
    avatarURL: URL?,
    targetPixel: CGFloat
  ) async -> NSImage? {
    let sourceURL = avatarURL ?? ReviewAvatarCache.fallbackAvatarURL(login: login)
    guard
      let sourceURL,
      let client = apiClient,
      let modelContainer = modelContext?.container
    else {
      return nil
    }
    return await ReviewAvatarCache.shared.avatar(
      for: sourceURL,
      targetPixel: targetPixel,
      modelContainer: modelContainer,
      client: client
    )
  }
}
