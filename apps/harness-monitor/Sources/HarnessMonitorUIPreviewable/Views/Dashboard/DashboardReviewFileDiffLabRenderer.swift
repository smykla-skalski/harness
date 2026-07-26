import AppKit
import HarnessMonitorKit

/// Headless renderer for the diff lab. Draws each fixture to a PNG off-screen
/// (no window, no focus change) so soft-wrap behaviour can be reviewed across
/// fixtures, view modes, and widths from the command line. The PreviewHost
/// executable invokes this when `HARNESS_DIFF_LAB_DUMP` is set, then exits
/// before any scene is shown.
@MainActor
public enum DashboardReviewFileDiffLabRenderer {
  /// Throws rather than skipping a fixture it cannot draw. A renderer that
  /// swallows its errors exits successfully having written nothing, and the
  /// missing image reads as a layout that produced no output.
  public static func dumpFixtures(
    toDirectory directory: String,
    widths: [CGFloat] = [480, 760, 1200]
  ) throws {
    let fileManager = FileManager.default
    try fileManager.createDirectory(
      atPath: directory,
      withIntermediateDirectories: true
    )
    for fixture in DashboardReviewFileDiffLabFixture.all {
      for mode in [FilesViewMode.split, FilesViewMode.unified] {
        for width in widths {
          try render(fixture: fixture, mode: mode, width: width, directory: directory)
        }
      }
    }
  }

  struct RenderFailure: Error, CustomStringConvertible {
    let fixture: String
    let reason: String

    var description: String { "\(fixture): \(reason)" }
  }

  private static func render(
    fixture: DashboardReviewFileDiffLabFixture,
    mode: FilesViewMode,
    width: CGFloat,
    directory: String
  ) throws {
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
    let name = "\(slug(fixture.title))-\(mode.rawValue)-\(Int(width))"
    guard view.bounds.width > 1, view.bounds.height > 1,
      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
    else {
      throw RenderFailure(fixture: name, reason: "view produced no drawable bitmap")
    }
    view.cacheDisplay(in: view.bounds, to: rep)
    guard let data = rep.representation(using: .png, properties: [:]), !data.isEmpty else {
      throw RenderFailure(fixture: name, reason: "bitmap did not encode to a non-empty PNG")
    }
    try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
  }

  private static func slug(_ title: String) -> String {
    String(
      title.lowercased().map { character in
        character.isLetter || character.isNumber ? character : "-"
      }
    )
  }
}
