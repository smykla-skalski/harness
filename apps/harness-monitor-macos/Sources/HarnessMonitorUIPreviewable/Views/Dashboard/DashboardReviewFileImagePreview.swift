import Foundation
import HarnessMonitorKit
import SwiftUI

/// Image preview pane for binary files. Drives the off-main decode
/// pipeline (`store.prepareImage(...)` → `ReviewImageDecoder`)
/// and renders the resulting `PreparedImage` as a decorative `Image`.
/// SVG sources are handled by the shared rasterizer the decoder
/// pipeline calls into.
struct DashboardReviewFileImagePreview: View {
  let file: ReviewFile
  let patch: ReviewFilePatch
  let pullRequestID: String
  let repositoryID: String
  let fontScale: CGFloat
  let captionFont: Font
  let caption2Font: Font

  @Environment(HarnessMonitorStore.self)
  private var store
  @Environment(\.reviewsPreferences)
  private var preferences
  @State private var prepared: ReviewImageDecoder.PreparedImage?
  @State private var failed: Bool = false
  @State private var loading: Bool = true

  @MainActor private static let byteCountFormatter: ByteCountFormatter = {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useKB, .useMB]
    formatter.countStyle = .file
    return formatter
  }()

  init(
    file: ReviewFile,
    patch: ReviewFilePatch,
    pullRequestID: String,
    repositoryID: String,
    fontScale: CGFloat
  ) {
    self.file = file
    self.patch = patch
    self.pullRequestID = pullRequestID
    self.repositoryID = repositoryID
    self.fontScale = fontScale
    captionFont = HarnessMonitorTextSize.scaledFont(.caption, by: fontScale)
    caption2Font = HarnessMonitorTextSize.scaledFont(.caption2, by: fontScale)
  }

  var body: some View {
    Group {
      if file.languageHint == .generic && !isImagePath {
        nonImageBinaryRow
      } else if isOverBudget {
        overBudgetRow
      } else if loading {
        loadingRow
      } else if let prepared {
        renderedImage(prepared)
      } else if failed {
        failedRow
      } else {
        nonImageBinaryRow
      }
    }
    .task(id: cacheTaskKey) { await load() }
    .accessibilityIdentifier("dashboardReviewFileImagePreview(\(file.path))")
  }

  private func renderedImage(_ image: ReviewImageDecoder.PreparedImage) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Image(decorative: image.cgImage, scale: 1, orientation: .up)
        .resizable()
        .aspectRatio(contentMode: .fit)
        .frame(maxWidth: 800, maxHeight: 800)
      Text(
        "\(Int(image.intrinsicSize.width))×\(Int(image.intrinsicSize.height)) · "
          + Self.humanizedBytes(image.byteSize)
      )
      .font(caption2Font)
      .foregroundStyle(.secondary)
      if patch.truncated {
        Text("Truncated by GitHub. Open on github.com for the full asset.")
          .font(caption2Font)
          .foregroundStyle(.orange)
      }
    }
  }

  private var loadingRow: some View {
    HStack(spacing: 8) {
      ProgressView().controlSize(.small)
      Text("Decoding preview…").font(captionFont).foregroundStyle(.secondary)
    }
  }

  private var failedRow: some View {
    Label(
      "Preview unavailable — daemon couldn't fetch the blob",
      systemImage: "exclamationmark.triangle"
    )
    .font(captionFont)
    .foregroundStyle(.orange)
  }

  private var overBudgetRow: some View {
    VStack(alignment: .leading, spacing: 4) {
      Label("Image too large to preview", systemImage: "photo.badge.exclamationmark")
        .font(captionFont)
        .foregroundStyle(.secondary)
      Text(
        "Larger than the configured limit (\(preferences.snapshot.filesImagePreviewMaxBytes / 1_048_576) MB)."
      )
      .font(caption2Font)
      .foregroundStyle(.secondary)
    }
  }

  private var nonImageBinaryRow: some View {
    Label("Binary file — no inline preview available", systemImage: "doc")
      .font(captionFont)
      .foregroundStyle(.secondary)
  }

  private var isImagePath: Bool { harnessImageMime(forPath: file.path) != nil }

  private var isOverBudget: Bool {
    // Patch metadata's `additions`/`deletions` aren't byte counts; the
    // budget check happens after decode (via PreparedImage.byteSize). The
    // pre-fetch gate stays on the preferences flag.
    preferences.snapshot.filesShowImagePreview == false
  }

  private var cacheTaskKey: String {
    "\(pullRequestID)\u{1F}\(repositoryID)\u{1F}\(file.path)"
  }

  private func load() async {
    guard preferences.snapshot.filesShowImagePreview else {
      loading = false
      prepared = nil
      return
    }
    loading = true
    failed = false
    let oid = patch.path.isEmpty ? file.path : patch.path
    let result = await store.prepareImage(
      pullRequestID: pullRequestID,
      repositoryID: repositoryID,
      oid: oid,
      path: file.path,
      displayMaxDimension: 800
    )
    loading = false
    prepared = result
    failed = result == nil
  }

  @MainActor
  private static func humanizedBytes(_ bytes: Int) -> String {
    byteCountFormatter.string(fromByteCount: Int64(bytes))
  }
}
