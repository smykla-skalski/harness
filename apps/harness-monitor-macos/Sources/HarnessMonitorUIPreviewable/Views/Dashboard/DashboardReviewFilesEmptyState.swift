import HarnessMonitorKit
import SwiftUI

/// Empty / loading / error / cloning states for the Files section.
struct DashboardReviewFilesEmptyState: View {
  enum Reason: Equatable {
    case loading
    case noFiles
    case filteredOut
    case error(message: String)
    /// Daemon is in the middle of `git clone` / `git fetch` via the
    /// local-clone runtime. The chip surfaces while the operation is
    /// in flight so the user understands why "Loading files..." takes
    /// longer than usual.
    case cloning(progress: ReviewLocalCloneProgress)
    /// Cached Reviews detail can render before daemon bootstrap finishes.
    /// Keep the Files section recoverable instead of storing a one-shot
    /// unavailable-client error.
    case waitingForDaemon
  }

  let reason: Reason
  let fontScale: CGFloat
  let titleFont: Font
  let subtitleFont: Font
  let captionFont: Font
  /// Optional escape hatch surfaced only while the daemon is cloning.
  /// When provided, the cloning empty-state offers a "Hide Files for
  /// this PR" button that dismisses the section locally without
  /// stopping the background clone or toggling the global setting.
  let onHideFilesForPR: (() -> Void)?

  @State private var cloningStartedAt: Date?

  init(
    reason: Reason,
    fontScale: CGFloat,
    onHideFilesForPR: (() -> Void)? = nil
  ) {
    self.reason = reason
    self.fontScale = fontScale
    titleFont = HarnessMonitorTextSize.scaledFont(.headline, by: fontScale)
    subtitleFont = HarnessMonitorTextSize.scaledFont(.subheadline, by: fontScale)
    captionFont = HarnessMonitorTextSize.scaledFont(.caption, by: fontScale)
    self.onHideFilesForPR = onHideFilesForPR
  }

  var body: some View {
    VStack(alignment: .center, spacing: 6) {
      icon
      Text(title).font(titleFont)
      if let subtitle {
        Text(subtitle).font(subtitleFont).foregroundStyle(.secondary)
      }
      cloningEscapeHatch
    }
    .frame(maxWidth: .infinity, alignment: .center)
    .padding(.vertical, 20)
    .accessibilityIdentifier("dashboardReviewFilesEmptyState")
    .accessibilityElement(children: .combine)
    .accessibilityLabel(Text(title))
    .onAppear {
      if case .cloning = reason, cloningStartedAt == nil {
        cloningStartedAt = Date.now
      }
    }
    .onChange(of: cloningIdentity) { _, newIdentity in
      cloningStartedAt = newIdentity == nil ? nil : Date.now
    }
  }

  @ViewBuilder private var cloningEscapeHatch: some View {
    if case .cloning = reason {
      TimelineView(.periodic(from: .now, by: 1)) { context in
        let startedAt = cloningStartedAt ?? context.date
        let elapsed = max(0, Int(context.date.timeIntervalSince(startedAt)))
        Text("Cloning for \(elapsed)s")
          .font(captionFont)
          .foregroundStyle(.secondary)
          .monospacedDigit()
          .accessibilityLabel("Cloning has been running for \(elapsed) seconds")
      }
      .padding(.top, 2)
      if let onHide = onHideFilesForPR {
        Button("Hide Files for this PR", action: onHide)
          .controlSize(.small)
          .help(
            "Hides the Files section for this pull request only. "
              + "The daemon keeps cloning in the background. "
              + "Re-enable globally in Settings > Reviews > Files."
          )
          .accessibilityIdentifier("dashboardReviewFilesHideForPRButton")
          .padding(.top, 4)
      }
    }
  }

  private var icon: some View {
    Group {
      switch reason {
      case .loading, .cloning:
        ProgressView()
      case .waitingForDaemon:
        Image(systemName: "antenna.radiowaves.left.and.right")
      case .noFiles:
        Image(systemName: "doc.text.magnifyingglass")
      case .filteredOut:
        Image(systemName: "line.3.horizontal.decrease.circle")
      case .error:
        Image(systemName: "exclamationmark.triangle")
          .foregroundStyle(.orange)
      }
    }
  }

  private var title: String {
    switch reason {
    case .loading: return "Loading files…"
    case .waitingForDaemon: return "Waiting for daemon connection"
    case .noFiles: return "No files changed in this pull request"
    case .filteredOut: return "All files are hidden by the current filter"
    case .error: return "Failed to load files"
    case .cloning(let progress):
      return "\(progress.operation.presentLabel) \(progress.repoFullName)…"
    }
  }

  private var subtitle: String? {
    switch reason {
    case .error(let message): return message
    case .waitingForDaemon:
      return "Files will load automatically when the daemon is available."
    case .cloning: return "Local clone in progress so we can show the diff offline."
    default: return nil
    }
  }

  /// Stable identity for the in-flight clone. `nil` when the reason
  /// isn't `.cloning`, otherwise the daemon-reported repo so that
  /// navigating between two cloning PRs (different repos) resets the
  /// elapsed-time counter instead of accumulating across PRs.
  private var cloningIdentity: String? {
    guard case .cloning(let progress) = reason else { return nil }
    return progress.repoFullName
  }
}
