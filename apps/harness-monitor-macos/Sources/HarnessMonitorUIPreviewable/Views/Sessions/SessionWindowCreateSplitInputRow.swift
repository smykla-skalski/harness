import SwiftUI

enum SessionWindowCreateSplitInputRowAlignment {
  case center
  case top
}

struct SessionWindowCreateSplitInputRow<Content: View, Accessory: View>: View {
  private let title: String
  private let verticalAlignment: SessionWindowCreateSplitInputRowAlignment
  private let accessory: Accessory
  private let content: Content

  init(
    _ title: String,
    verticalAlignment: SessionWindowCreateSplitInputRowAlignment = .center,
    @ViewBuilder accessory: () -> Accessory,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.verticalAlignment = verticalAlignment
    self.accessory = accessory()
    self.content = content()
  }

  init(
    _ title: String,
    verticalAlignment: SessionWindowCreateSplitInputRowAlignment = .center,
    @ViewBuilder content: () -> Content
  ) where Accessory == EmptyView {
    self.title = title
    self.verticalAlignment = verticalAlignment
    accessory = EmptyView()
    self.content = content()
  }

  var body: some View {
    SessionWindowCreateSplitInputRowLayout(verticalAlignment: verticalAlignment) {
      HStack(alignment: .center, spacing: HarnessMonitorTheme.spacingXS) {
        Text(title)
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 0)
        accessory
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      content
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

private struct SessionWindowCreateSplitInputRowLayout: Layout {
  let labelFraction: CGFloat = 0.30
  let fieldFraction: CGFloat = 0.70
  var spacing: CGFloat = HarnessMonitorTheme.spacingSM
  let verticalAlignment: SessionWindowCreateSplitInputRowAlignment

  func sizeThatFits(
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache _: inout ()
  ) -> CGSize {
    guard subviews.count == 2 else { return .zero }

    guard let width = proposal.width else {
      let labelSize = subviews[0].sizeThatFits(.unspecified)
      let fieldSize = subviews[1].sizeThatFits(.unspecified)
      return CGSize(
        width: labelSize.width + spacing + fieldSize.width,
        height: max(labelSize.height, fieldSize.height)
      )
    }

    let proposals = splitProposals(for: width, height: proposal.height)
    let labelSize = subviews[0].sizeThatFits(proposals.label)
    let fieldSize = subviews[1].sizeThatFits(proposals.field)

    return CGSize(width: width, height: max(labelSize.height, fieldSize.height))
  }

  func placeSubviews(
    in bounds: CGRect,
    proposal _: ProposedViewSize,
    subviews: Subviews,
    cache _: inout ()
  ) {
    guard subviews.count == 2 else { return }

    let proposals = splitProposals(for: bounds.width, height: bounds.height)
    let labelSize = subviews[0].sizeThatFits(proposals.label)
    let fieldSize = subviews[1].sizeThatFits(proposals.field)

    subviews[0].place(
      at: CGPoint(x: bounds.minX, y: yOrigin(for: labelSize.height, in: bounds)),
      anchor: .topLeading,
      proposal: proposals.label
    )

    subviews[1].place(
      at: CGPoint(
        x: bounds.minX + proposals.label.width! + spacing,
        y: yOrigin(for: fieldSize.height, in: bounds)
      ),
      anchor: .topLeading,
      proposal: proposals.field
    )
  }

  private func splitProposals(for width: CGFloat, height: CGFloat?) -> (
    label: ProposedViewSize,
    field: ProposedViewSize
  ) {
    let availableWidth = max(width - spacing, 0)
    let labelWidth = availableWidth * labelFraction
    let fieldWidth = availableWidth * fieldFraction

    return (
      ProposedViewSize(width: labelWidth, height: height),
      ProposedViewSize(width: fieldWidth, height: height)
    )
  }

  private func yOrigin(for height: CGFloat, in bounds: CGRect) -> CGFloat {
    switch verticalAlignment {
    case .center:
      bounds.minY + max((bounds.height - height) / 2, 0)
    case .top:
      bounds.minY
    }
  }
}
