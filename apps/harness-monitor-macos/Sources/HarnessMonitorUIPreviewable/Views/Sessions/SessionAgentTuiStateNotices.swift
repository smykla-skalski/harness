import HarnessMonitorKit
import SwiftUI

struct SessionAgentTuiNoticeMetrics: Equatable {
  let spacing: CGFloat
  let textSpacing: CGFloat
  let padding: CGFloat
  let cornerRadius: CGFloat

  init(fontScale: CGFloat) {
    let scale = SessionWindowFontScale.metricsScale(for: fontScale)
    spacing = 12 * min(scale, 1.35)
    textSpacing = 4 * min(scale, 1.45)
    padding = 12 * min(scale, 1.35)
    cornerRadius = 10 * min(scale, 1.2)
  }
}

struct SessionAgentTuiErrorBanner: View {
  let message: String
  @Environment(\.fontScale)
  private var fontScale

  private var metrics: SessionAgentTuiNoticeMetrics {
    SessionAgentTuiNoticeMetrics(fontScale: fontScale)
  }

  var body: some View {
    HStack(alignment: .top, spacing: metrics.spacing) {
      Image(systemName: "exclamationmark.triangle.fill")
        .scaledFont(.body)
        .foregroundStyle(.red)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: metrics.textSpacing) {
        Text("Terminal error")
          .scaledFont(.headline)
        Text(message)
          .scaledFont(.subheadline)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
      Spacer(minLength: 0)
    }
    .padding(metrics.padding)
    .dynamicTypeSize(.xSmall ... .accessibility5)
    .background {
      RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
        .fill(.regularMaterial)
    }
    .overlay {
      RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
        .stroke(.quaternary, lineWidth: 1)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Terminal error: \(message)")
  }
}

struct SessionAgentTuiOutcomeBanner: View {
  let exitCode: UInt32?
  let signal: String?
  @Environment(\.fontScale)
  private var fontScale

  private var metrics: SessionAgentTuiNoticeMetrics {
    SessionAgentTuiNoticeMetrics(fontScale: fontScale)
  }

  var body: some View {
    HStack(alignment: .top, spacing: metrics.spacing) {
      Image(systemName: "stop.circle")
        .scaledFont(.body)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: metrics.textSpacing) {
        Text("Terminal exited")
          .scaledFont(.headline)
        if let exitCode {
          Text("Exit code \(exitCode)")
            .scaledFont(.subheadline)
            .foregroundStyle(.secondary)
        }
        if let signal, !signal.isEmpty {
          Text("Signal \(signal)")
            .scaledFont(.subheadline)
            .foregroundStyle(.secondary)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(metrics.padding)
    .dynamicTypeSize(.xSmall ... .accessibility5)
    .background {
      RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
        .fill(.regularMaterial)
    }
    .overlay {
      RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
        .stroke(.quaternary, lineWidth: 1)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(Self.accessibilityLabel(exitCode: exitCode, signal: signal))
  }

  static func accessibilityLabel(exitCode: UInt32?, signal: String?) -> String {
    var parts = ["Terminal exited"]
    if let exitCode {
      parts.append("Exit code \(exitCode)")
    }
    if let signal, !signal.isEmpty {
      parts.append("Signal \(signal)")
    }
    return parts.joined(separator: ". ")
  }
}

struct SessionAgentTuiPendingPromptBanner: View {
  let prompt: AgentPendingUserPrompt
  @Environment(\.fontScale)
  private var fontScale

  private var metrics: SessionAgentTuiNoticeMetrics {
    SessionAgentTuiNoticeMetrics(fontScale: fontScale)
  }

  var body: some View {
    HStack(alignment: .top, spacing: metrics.spacing) {
      Image(systemName: "questionmark.bubble.fill")
        .scaledFont(.body)
        .foregroundStyle(.orange)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: metrics.textSpacing) {
        Text("User input required")
          .scaledFont(.headline)
        if let waitingSince = prompt.waitingSince, !waitingSince.isEmpty {
          Text("Waiting since \(waitingSince)")
            .scaledFont(.footnote.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        ForEach(Array(prompt.questions.enumerated()), id: \.offset) { _, question in
          questionBlock(question)
        }
        Text("Reply with the composer below to unblock the agent.")
          .scaledFont(.footnote)
          .foregroundStyle(.secondary)
          .padding(.top, 2)
      }
      Spacer(minLength: 0)
    }
    .padding(metrics.padding)
    .dynamicTypeSize(.xSmall ... .accessibility5)
    .background {
      RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
        .fill(.regularMaterial)
    }
    .overlay {
      RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
        .stroke(.quaternary, lineWidth: 1)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Self.accessibilitySummary(prompt))
    .accessibilityHint("Use the composer below to answer the pending user prompt.")
  }

  @ViewBuilder
  private func questionBlock(_ question: AgentPendingUserPromptQuestion) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      if let header = question.header, !header.isEmpty {
        Text(header)
          .scaledFont(.caption.bold())
          .foregroundStyle(.secondary)
      }
      Text(question.question)
        .scaledFont(.subheadline)
        .textSelection(.enabled)
      if !question.options.isEmpty {
        Text(question.multiSelect ? "Choose one or more" : "Choose one")
          .scaledFont(.caption.bold())
          .foregroundStyle(.secondary)
        ForEach(Array(question.options.enumerated()), id: \.offset) { _, option in
          Text(Self.optionText(option))
            .scaledFont(.footnote)
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  static func optionText(_ option: AgentPendingUserPromptOption) -> String {
    if option.description.isEmpty {
      "- \(option.label)"
    } else {
      "- \(option.label): \(option.description)"
    }
  }

  static func accessibilitySummary(_ prompt: AgentPendingUserPrompt) -> String {
    let questions = prompt.questions.map { question -> String in
      if question.options.isEmpty {
        return question.question
      }
      let options = question.options.map(\.label).joined(separator: ", ")
      return "\(question.question) Options: \(options)."
    }
    return (["User input required"] + questions).joined(separator: " ")
  }
}
