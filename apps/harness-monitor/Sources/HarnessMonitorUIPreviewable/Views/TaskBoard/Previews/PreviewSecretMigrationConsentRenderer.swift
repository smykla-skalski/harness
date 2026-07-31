import AppKit
import HarnessMonitorKit
import SwiftUI

/// Shell snapshots for the cross-daemon secret review sheet.
public enum SecretMigrationConsentPreviewRenderer {
  private static func item(
    _ kind: TaskBoardSecretKind,
    _ disposition: TaskBoardSecretMigrationItem.Disposition
  ) -> TaskBoardSecretMigrationItem {
    TaskBoardSecretMigrationItem(kind: kind, disposition: disposition)
  }

  private static let carryOverOnly: [TaskBoardSecretMigrationItem] = [
    item(.githubGlobalToken, .carryOver),
    item(.openRouterToken, .carryOver),
    item(.sshKey, .carryOver),
    item(.gpgKey, .carryOver),
  ]

  private static let singleConflict: [TaskBoardSecretMigrationItem] = [
    item(.githubGlobalToken, .conflict)
  ]

  private static let mixed: [TaskBoardSecretMigrationItem] = [
    item(.githubGlobalToken, .conflict),
    item(.gpgKey, .conflict),
    item(.sshKey, .carryOver),
    item(.signingSSHKey, .carryOver),
    item(.openRouterToken, .carryOver),
  ]

  private static let withRepositories: [TaskBoardSecretMigrationItem] =
    mixed + [
      item(.repositoryGitHubToken("acme/backend"), .conflict),
      item(.repositorySSHKey("acme/backend"), .carryOver),
    ]

  @MainActor
  public static func dump(toDirectory directory: String) -> Bool {
    do {
      try FileManager.default.createDirectory(
        atPath: directory,
        withIntermediateDirectories: true
      )
    } catch {
      return false
    }

    let defaultIndex = HarnessMonitorTextSize.defaultIndex
    let largestIndex = HarnessMonitorTextSize.scales.count - 1
    return render(
      name: "consent-carry-over-only",
      width: 560,
      textSizeIndex: defaultIndex,
      directory: directory,
      items: carryOverOnly
    )
      && render(
        name: "consent-single-conflict",
        width: 560,
        textSizeIndex: defaultIndex,
        directory: directory,
        items: singleConflict
      )
      && render(
        name: "consent-conflicts-and-carryovers",
        width: 600,
        textSizeIndex: defaultIndex,
        directory: directory,
        items: mixed
      )
      && render(
        name: "consent-with-repositories",
        width: 600,
        textSizeIndex: defaultIndex,
        directory: directory,
        items: withRepositories
      )
      && render(
        name: "consent-conflicts-and-carryovers-largest-text",
        width: 680,
        textSizeIndex: largestIndex,
        directory: directory,
        items: mixed
      )
  }

  @MainActor
  private static func render(
    name: String,
    width: CGFloat,
    textSizeIndex: Int,
    directory: String,
    items: [TaskBoardSecretMigrationItem]
  ) -> Bool {
    let hosted =
      SecretMigrationConsentSheet(store: SettingsPreviewSupport.makeStore(), items: items)
      .frame(width: width, alignment: .topLeading)
      .background(Color(nsColor: .windowBackgroundColor))
      .harnessPreviewSceneAppearance(textSizeIndex: textSizeIndex)
    let view = NSHostingView(rootView: hosted)
    view.appearance = NSAppearance(named: .darkAqua)
    // Size the capture to the sheet's own fitting height so the snapshot shows
    // the same hug-to-content layout the app presents, with no padded gap.
    let height = max(view.fittingSize.height, 1)
    let size = NSSize(width: width, height: height)
    view.setFrameSize(size)
    view.layoutSubtreeIfNeeded()

    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
      return false
    }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let data = bitmap.representation(using: .png, properties: [:]), !data.isEmpty else {
      return false
    }

    do {
      try data.write(
        to: URL(fileURLWithPath: directory)
          .appendingPathComponent(name)
          .appendingPathExtension("png"),
        options: .atomic
      )
      return true
    } catch {
      return false
    }
  }
}
