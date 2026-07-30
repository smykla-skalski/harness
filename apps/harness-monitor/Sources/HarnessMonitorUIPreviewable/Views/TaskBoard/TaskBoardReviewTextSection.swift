import SwiftUI

struct TaskBoardReviewTextSection: View {
  let title: String
  let systemImage: String
  let content: String
  var collapsedLineLimit: Int?
  @State private var isExpanded: Bool
  @State private var isTruncated = false
  @State private var fullTextHeight: CGFloat = 0
  @State private var visibleTextHeight: CGFloat = 0
  @Environment(\.fontScale)
  private var fontScale

  init(
    title: String,
    systemImage: String,
    content: String,
    collapsedLineLimit: Int? = nil,
    initiallyExpanded: Bool = false
  ) {
    self.title = title
    self.systemImage = systemImage
    self.content = content
    self.collapsedLineLimit = collapsedLineLimit
    _isExpanded = State(initialValue: initiallyExpanded)
  }

  private var proseFont: Font {
    HarnessMonitorTextSize.scaledFont(.callout, by: fontScale)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
      TaskBoardReviewSectionHeader(title: title, systemImage: systemImage)
        .padding(.horizontal, HarnessMonitorTheme.spacingSM)
      VStack(alignment: .leading, spacing: 0) {
        text
          .padding(HarnessMonitorTheme.spacingSM)
        if canExpand {
          Divider()
          TaskBoardReviewDisclosureButton(
            collapsedTitle: "Show more",
            expandedTitle: "Show less",
            isExpanded: $isExpanded
          )
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(HarnessMonitorTheme.ink.opacity(0.04), in: .rect(cornerRadius: 8))
      .overlay {
        RoundedRectangle(cornerRadius: 8)
          .strokeBorder(HarnessMonitorTheme.ink.opacity(0.1))
      }
    }
  }

  @ViewBuilder private var text: some View {
    if isExpanded {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
        ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
          proseText(paragraph)
        }
      }
    } else {
      proseText(content)
        .lineLimit(collapsedLineLimit)
        .background {
          if collapsedLineLimit != nil {
            proseText(content)
              .hidden()
              .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
              } action: { fullHeight in
                fullTextHeight = fullHeight
                updateTruncation()
              }
          }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
          proxy.size.height
        } action: { visibleHeight in
          visibleTextHeight = visibleHeight
          updateTruncation()
        }
    }
  }

  private var paragraphs: [String] {
    content
      .components(separatedBy: "\n\n")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  private var canExpand: Bool {
    collapsedLineLimit != nil && (isTruncated || isExpanded)
  }

  private func proseText(_ value: String) -> some View {
    Text(value)
      .font(proseFont)
      .foregroundStyle(HarnessMonitorTheme.ink.opacity(0.9))
      .lineSpacing(HarnessMonitorTheme.spacingXS)
      .multilineTextAlignment(.leading)
      .textSelection(.enabled)
      .fixedSize(horizontal: false, vertical: true)
  }

  private func updateTruncation() {
    guard fullTextHeight > 0, visibleTextHeight > 0 else { return }
    isTruncated = fullTextHeight > visibleTextHeight + 0.5
  }
}
