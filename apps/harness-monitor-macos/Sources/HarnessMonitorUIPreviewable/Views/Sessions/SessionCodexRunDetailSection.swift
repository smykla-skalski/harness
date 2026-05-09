import HarnessMonitorKit
import SwiftUI

struct SessionCodexRunDetailSection: View {
  let store: HarnessMonitorStore
  let run: CodexRunSnapshot
  @Environment(\.fontScale)
  private var fontScale

  private var metrics: SessionAgentDetailSectionMetrics {
    SessionAgentDetailSectionMetrics(fontScale: fontScale)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: metrics.sectionSpacing) {
      header
      if let error = run.error, !error.isEmpty {
        SessionAgentTuiErrorBanner(message: error)
      }
      VStack(alignment: .leading, spacing: 6) {
        Text("Prompt")
          .scaledFont(.caption.bold())
          .foregroundStyle(.secondary)
        Text(run.prompt.isEmpty ? "(empty prompt)" : run.prompt)
          .scaledFont(.body)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(metrics.terminalPadding)
      .background(
        .quaternary.opacity(0.4),
        in: RoundedRectangle(cornerRadius: metrics.terminalCornerRadius)
      )
      if let summary = run.latestSummary, !summary.isEmpty {
        block(label: "Latest update", body: summary)
      }
      if let final = run.finalMessage, !final.isEmpty {
        block(label: "Final message", body: final)
      }
      Spacer(minLength: 0)
    }
    .padding(metrics.sectionPadding)
    .dynamicTypeSize(.xSmall ... .accessibility5)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: metrics.headerSpacing) {
      Text(SessionCodexRunRowFormatter.title(for: run))
        .scaledFont(.title3.weight(.semibold))
        .lineLimit(2)
      Text("Codex • \(run.mode.title) • \(run.status.title)")
        .scaledFont(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder
  private func block(label: String, body: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(label)
        .scaledFont(.caption.bold())
        .foregroundStyle(.secondary)
      Text(body)
        .scaledFont(.body)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(metrics.terminalPadding)
    .background(
      .quaternary.opacity(0.25),
      in: RoundedRectangle(cornerRadius: metrics.terminalCornerRadius)
    )
  }
}
