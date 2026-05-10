import HarnessMonitorKit
import SwiftUI

struct SessionWindowCreateSectionCard<Content: View>: View {
  private let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    content
      .padding(.vertical, HarnessMonitorTheme.spacingSM)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct SessionWindowCreateSectionHeading: View {
  let title: String
  let description: String?

  init(title: String, description: String? = nil) {
    self.title = title
    self.description = description
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      Text(title)
        .scaledFont(.headline)
        .accessibilityAddTraits(.isHeader)

      if let description {
        Text(description)
          .scaledFont(.subheadline)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

struct SessionWindowCreateFieldBlock<Content: View>: View {
  let title: String
  let help: String?
  private let content: Content

  init(
    title: String,
    help: String? = nil,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.help = help
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      Text(title)
        .scaledFont(.caption.bold())
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)

      content

      if let help {
        Text(help)
          .scaledFont(.caption)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

struct SessionWindowCreateProviderButtonList: View {
  let options: [AgentCapabilityOption]
  let selectedProviderID: String?
  let onSelect: (AgentCapabilityOption) -> Void

  var body: some View {
    VStack(spacing: HarnessMonitorTheme.spacingXS) {
      ForEach(options) { option in
        Button {
          onSelect(option)
        } label: {
          SessionWindowCreateProviderListRow(
            option: option,
            isSelected: selectedProviderID == option.id
          )
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(SessionWindowCreateProviderListRow.accessibilityLabel(for: option))
        .accessibilityValue(selectedProviderID == option.id ? "Selected" : "")
        .accessibilityHint("Chooses \(option.title)")
      }
    }
  }
}

struct SessionWindowCreateDiagnosticsDisclosure: View {
  let option: AgentCapabilityOption
  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion
  @State private var isExpanded = false

  var body: some View {
    if let doctorProbeText = option.doctorProbeText {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
        Button(isExpanded ? "Hide setup details" : "Show setup details") {
          if reduceMotion {
            isExpanded.toggle()
          } else {
            withAnimation(.easeOut(duration: 0.18)) {
              isExpanded.toggle()
            }
          }
        }
        .harnessActionButtonStyle(variant: .bordered, tint: .secondary)
        .controlSize(HarnessMonitorControlMetrics.compactControlSize)
        .accessibilityLabel(
          "\(isExpanded ? "Hide" : "Show") setup details for \(option.title)"
        )
        .accessibilityHint(doctorProbeText)

        if isExpanded {
          Text(doctorProbeText)
            .scaledFont(.caption.monospaced())
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
        }
      }
    }
  }
}
