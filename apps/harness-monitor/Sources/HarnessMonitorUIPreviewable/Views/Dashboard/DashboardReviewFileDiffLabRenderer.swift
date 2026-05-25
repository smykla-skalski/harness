import AppKit
import HarnessMonitorKit

/// Headless renderer for the diff lab. Draws each fixture to a PNG off-screen
/// (no window, no focus change) so soft-wrap behaviour can be reviewed across
/// fixtures, view modes, and widths from the command line. The PreviewHost
/// executable invokes this when `HARNESS_DIFF_LAB_DUMP` is set, then exits
/// before any scene is shown.
@MainActor
public enum DashboardReviewFileDiffLabRenderer {
  public static func dumpFixtures(
    toDirectory directory: String,
    widths: [CGFloat] = [480, 760, 1200]
  ) {
    let fileManager = FileManager.default
    try? fileManager.createDirectory(
      atPath: directory,
      withIntermediateDirectories: true
    )
    for fixture in DashboardReviewFileDiffLabFixture.all {
      for mode in [FilesViewMode.split, FilesViewMode.unified] {
        for width in widths {
          render(fixture: fixture, mode: mode, width: width, directory: directory)
        }
      }
    }
  }

  private static func render(
    fixture: DashboardReviewFileDiffLabFixture,
    mode: FilesViewMode,
    width: CGFloat,
    directory: String
  ) {
    let document = DashboardReviewFileDiffDocument(
      patch: fixture.patch,
      language: fixture.language,
      tabWidth: 8
    )
    let view = DashboardReviewFileDiffGridContentView()
    view.configure(
      .init(
        document: document,
        viewMode: mode,
        fontScale: 1
      )
    )
    view.setFrameSize(NSSize(width: width, height: 32))
    view.resizeForViewportWidth(width)
    guard view.bounds.width > 1, view.bounds.height > 1,
      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
    else { return }
    view.cacheDisplay(in: view.bounds, to: rep)
    guard let data = rep.representation(using: .png, properties: [:]) else { return }
    let name = "\(slug(fixture.title))-\(mode.rawValue)-\(Int(width)).png"
    try? data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
  }

  private static func slug(_ title: String) -> String {
    String(
      title.lowercased().map { character in
        character.isLetter || character.isNumber ? character : "-"
      }
    )
  }
}
