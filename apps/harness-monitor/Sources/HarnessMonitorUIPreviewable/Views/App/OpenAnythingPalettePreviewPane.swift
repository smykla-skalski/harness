import HarnessMonitorKit
import SwiftUI

/// Side pane that surfaces the selected hit's expanded metadata when the host
/// window has room. The palette mounts this view only when the available width crosses
/// `OpenAnythingPaletteConstants.previewPaneActivationWidth` so narrow
/// windows keep their original single-column layout untouched.
struct OpenAnythingPalettePreviewPane: View {
  let hit: OpenAnythingHit?

  var body: some View {
    Group {
      if let hit {
        content(for: hit)
      } else {
        placeholder
      }
    }
    .frame(width: OpenAnythingPaletteConstants.previewPaneWidth)
    .frame(maxHeight: .infinity, alignment: .top)
    .padding(.horizontal, 18)
    .padding(.vertical, 16)
    .background(
      HarnessMonitorTheme.ink
        .opacity(OpenAnythingPaletteConstants.sectionHeaderFillOpacity)
    )
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Open Anything preview")
  }

  @ViewBuilder
  private func content(for hit: OpenAnythingHit) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      header(for: hit)
      Divider()
      if let subtitle = hit.record.subtitle, !subtitle.isEmpty {
        labeledRow(title: "Subtitle", value: subtitle)
      }
      if let trailing = hit.record.trailing, !trailing.isEmpty {
        labeledRow(title: "Status", value: trailing)
      }
      labeledRow(title: "Domain", value: hit.domain.label)
      labeledRow(title: "Identifier", value: hit.id, isMonospaced: true)
      if let searchBodyPreview = Self.previewSearchBody(hit.record.searchBody) {
        labeledRow(title: "Match body", value: searchBodyPreview)
      }
      Spacer(minLength: 0)
    }
  }

  static func previewSearchBody(_ searchBody: String) -> String? {
    let trimmed = searchBody.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let preview = trimmed.prefix(searchBodyPreviewLimit + 1)
    guard preview.count > searchBodyPreviewLimit else {
      return trimmed
    }
    return String(preview.prefix(searchBodyPreviewLimit)) + "..."
  }

  private func header(for hit: OpenAnythingHit) -> some View {
    HStack(spacing: 10) {
      Image(systemName: hit.record.systemImage)
        .symbolRenderingMode(.hierarchical)
        .font(.title3)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      Text(hit.record.title)
        .font(.headline)
        .lineLimit(2)
    }
  }

  private func labeledRow(
    title: String,
    value: String,
    isMonospaced: Bool = false
  ) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title.uppercased())
        .font(.caption2)
        .foregroundStyle(HarnessMonitorTheme.tertiaryInk)
      Text(value)
        .font(isMonospaced ? .callout.monospaced() : .callout)
        .foregroundStyle(.primary)
        .textSelection(.enabled)
    }
  }

  private var placeholder: some View {
    VStack(spacing: 6) {
      Image(systemName: "doc.text.magnifyingglass")
        .font(.title2)
        .foregroundStyle(HarnessMonitorTheme.tertiaryInk)
      Text("Select a result to preview")
        .font(.callout)
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private static let searchBodyPreviewLimit = 480
}
