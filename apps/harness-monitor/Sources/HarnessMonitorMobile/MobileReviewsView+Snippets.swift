import HarnessMonitorCore
import SwiftUI

struct MobileReviewSnippetGroup<Content: View>: View {
  let title: LocalizedStringKey
  let content: Content

  init(title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title)
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
      content
    }
  }
}

struct MobileReviewCheckSnippetRow: View {
  let check: MobileReviewCheckSnippet

  var body: some View {
    HStack(spacing: 4) {
      Image(systemName: iconName)
        .imageScale(.medium)
        .foregroundStyle(iconColor)
        .accessibilityHidden(true)
      HStack {
        Text(check.name)
          .lineLimit(1)
        Spacer(minLength: 8)
        Text(statusText)
          .foregroundStyle(.secondary)
      }
      .font(.caption)
    }
    .accessibilityElement(children: .combine)
  }

  private var statusText: String {
    if check.conclusion != "none" {
      return Self.displayStatus(check.conclusion)
    }
    return Self.displayStatus(check.status)
  }

  private static func displayStatus(_ value: String) -> String {
    value
      .replacingOccurrences(of: "_", with: " ")
      .capitalized
  }

  private var iconName: String {
    switch check.conclusion {
    case "success":
      "checkmark.circle.fill"
    case "failure", "timed_out", "cancelled":
      "xmark.octagon.fill"
    default:
      check.status == "completed" ? "circle" : "clock.fill"
    }
  }

  private var iconColor: Color {
    switch check.conclusion {
    case "success":
      .green
    case "failure", "timed_out", "cancelled":
      .red
    default:
      .orange
    }
  }
}

struct MobileReviewFileSnippetRow: View {
  let file: MobileReviewFileSnippet

  var body: some View {
    HStack(spacing: 6) {
      Text(changeLabel)
        .font(.caption2.weight(.bold))
        .foregroundStyle(changeColor)
        .frame(width: 28, alignment: .leading)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
      Text(displayPath)
        .font(.caption)
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer(minLength: 8)
      Text("+\(file.additions) -\(file.deletions)")
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .combine)
  }

  private var changeColor: Color {
    switch file.changeType {
    case "added":
      .green
    case "deleted":
      .red
    case "renamed", "copied":
      .blue
    default:
      .secondary
    }
  }

  private var changeLabel: String {
    switch file.changeType {
    case "added":
      "add"
    case "deleted":
      "del"
    case "modified":
      "mod"
    case "renamed":
      "ren"
    case "copied":
      "copy"
    default:
      file.changeType
    }
  }

  private var displayPath: String {
    URL(fileURLWithPath: file.path).lastPathComponent
  }
}

struct MobileReviewActivitySnippetRow: View {
  let activity: MobileReviewActivitySnippet

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: "clock")
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      Text(activity.actor.map { "\($0) " } ?? "")
        .font(.caption.weight(.semibold))
      Text(activity.summary)
        .font(.caption)
        .lineLimit(1)
      Spacer(minLength: 8)
      Text(activity.recordedAt.formatted(.relative(presentation: .numeric)))
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .combine)
  }
}
