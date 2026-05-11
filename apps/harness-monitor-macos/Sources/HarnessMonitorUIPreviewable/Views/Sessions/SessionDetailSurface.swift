import HarnessMonitorKit
import SwiftUI

struct SessionDetailScrollSurface<Content: View, BottomInset: View>: View {
  let contentPadding: CGFloat
  let bottomInsetSpacing: CGFloat
  private let content: Content
  private let bottomInset: BottomInset?

  init(
    contentPadding: CGFloat,
    @ViewBuilder content: () -> Content
  ) where BottomInset == EmptyView {
    self.contentPadding = contentPadding
    bottomInsetSpacing = 0
    self.content = content()
    bottomInset = nil
  }

  init(
    contentPadding: CGFloat,
    bottomInsetSpacing: CGFloat = HarnessMonitorTheme.spacingMD,
    @ViewBuilder bottomInset: () -> BottomInset,
    @ViewBuilder content: () -> Content
  ) {
    self.contentPadding = contentPadding
    self.bottomInsetSpacing = bottomInsetSpacing
    self.content = content()
    self.bottomInset = bottomInset()
  }

  var body: some View {
    Group {
      if let bottomInset {
        HarnessMonitorColumnScrollView(
          horizontalPadding: contentPadding,
          verticalPadding: contentPadding,
          constrainContentWidth: false,
          readableWidth: false,
          topScrollEdgeEffect: .hard,
          bottomInsetSpacing: bottomInsetSpacing,
          bottomInset: {
            bottomInset
          },
          content: {
            content
              .frame(maxWidth: .infinity, alignment: .topLeading)
          }
        )
      } else {
        HarnessMonitorColumnScrollView(
          horizontalPadding: contentPadding,
          verticalPadding: contentPadding,
          constrainContentWidth: false,
          readableWidth: false,
          topScrollEdgeEffect: .hard
        ) {
          content
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
      }
    }
    .scrollBounceBehavior(.always, axes: .vertical)
  }
}

struct SessionDetailEmptySurface<Content: View>: View {
  let contentPadding: CGFloat
  private let content: Content

  init(
    contentPadding: CGFloat = HarnessMonitorTheme.spacingXXL,
    @ViewBuilder content: () -> Content
  ) {
    self.contentPadding = contentPadding
    self.content = content()
  }

  var body: some View {
    GeometryReader { geometry in
      SessionDetailScrollSurface(contentPadding: contentPadding) {
        VStack(spacing: 0) {
          Spacer(minLength: 0)
          content
            .frame(maxWidth: .infinity, alignment: .center)
          Spacer(minLength: 0)
        }
        .frame(
          minHeight: max(geometry.size.height - (contentPadding * 2), 0),
          alignment: .center
        )
        .frame(maxWidth: .infinity, alignment: .center)
      }
    }
  }
}

struct SessionDetailPanel<Content: View>: View {
  let title: String
  private let content: Content

  init(title: String, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
      Text(title)
        .scaledFont(.caption.bold())
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .accessibilityAddTraits(.isHeader)

      content
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(HarnessMonitorTheme.cardPadding)
    .background {
      RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusMD, style: .continuous)
        .fill(HarnessMonitorTheme.ink.opacity(0.04))
    }
    .overlay {
      RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusMD, style: .continuous)
        .strokeBorder(HarnessMonitorTheme.controlBorder.opacity(0.32), lineWidth: 1)
    }
  }
}

struct SessionDetailFact: Identifiable {
  let label: String
  let value: String
  let monospaced: Bool
  var id: String { label }

  init(_ label: String, value: String, monospaced: Bool = false) {
    self.label = label
    self.value = value
    self.monospaced = monospaced
  }
}

struct SessionDetailFactsGrid: View {
  let facts: [SessionDetailFact]

  var body: some View {
    Grid(
      alignment: .leading,
      horizontalSpacing: HarnessMonitorTheme.spacingMD,
      verticalSpacing: HarnessMonitorTheme.spacingSM
    ) {
      ForEach(facts) { fact in
        GridRow(alignment: .firstTextBaseline) {
          Text(fact.label)
            .scaledFont(.caption)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)

          if fact.monospaced {
            Text(verbatim: fact.value)
              .scaledFont(.body.monospaced())
              .textSelection(.enabled)
              .fixedSize(horizontal: false, vertical: true)
              .frame(maxWidth: .infinity, alignment: .leading)
          } else {
            Text(verbatim: fact.value)
              .scaledFont(.body)
              .textSelection(.enabled)
              .fixedSize(horizontal: false, vertical: true)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
