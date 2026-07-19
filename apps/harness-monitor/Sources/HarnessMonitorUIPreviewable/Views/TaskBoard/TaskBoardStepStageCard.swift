import SwiftUI

/// The focused stage card: the stage title with its primary Next action, what
/// just happened, what Next will do, and a slot for secondary controls.
/// Presentational only - the parent supplies the buttons so this view stores no
/// action closures.
struct TaskBoardStepStageCard<Primary: View, Actions: View>: View {
  let stageTitle: String
  let whatHappened: String?
  let whatNext: String
  private let primary: Primary
  private let actions: Actions

  @Environment(\.fontScale)
  private var fontScale

  init(
    stageTitle: String,
    whatHappened: String?,
    whatNext: String,
    @ViewBuilder primary: () -> Primary,
    @ViewBuilder actions: () -> Actions
  ) {
    self.stageTitle = stageTitle
    self.whatHappened = whatHappened
    self.whatNext = whatNext
    self.primary = primary()
    self.actions = actions()
  }

  private var titleFont: Font {
    HarnessMonitorTextSize.scaledFont(.title3.weight(.semibold), by: fontScale)
  }

  /// Stack the title and primary action vertically once the text scale is large
  /// enough that a side-by-side row would crowd the button against the title.
  private var stacksHeader: Bool { fontScale >= 1.3 }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingMD) {
      header
      if let whatHappened {
        TaskBoardStepStageBlock(
          label: "Just happened",
          systemImage: "clock.arrow.circlepath",
          text: whatHappened,
          tint: .secondary
        )
      }
      TaskBoardStepStageBlock(
        label: "Next",
        systemImage: "arrow.forward.circle",
        text: whatNext,
        tint: HarnessMonitorTheme.accent,
        emphasized: true
      )
      actions
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(HarnessMonitorTheme.spacingLG)
    .background(
      HarnessMonitorTheme.ink.opacity(0.05),
      in: .rect(cornerRadius: HarnessMonitorTheme.cornerRadiusSM)
    )
    .overlay {
      RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusSM)
        .strokeBorder(HarnessMonitorTheme.ink.opacity(0.08))
    }
    .accessibilityIdentifier("harness.task-board.step.stage-card")
  }

  @ViewBuilder private var header: some View {
    if stacksHeader {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
        titleText
        primary
      }
    } else {
      HStack(alignment: .firstTextBaseline, spacing: HarnessMonitorTheme.spacingMD) {
        titleText
        Spacer(minLength: HarnessMonitorTheme.spacingMD)
        primary
      }
    }
  }

  private var titleText: some View {
    Text(stageTitle)
      .font(titleFont)
      .accessibilityAddTraits(.isHeader)
      .fixedSize(horizontal: false, vertical: true)
  }
}

/// A labelled explanation block inside the stage card. The forward-looking
/// "Next" block is emphasized with a leading accent rule.
private struct TaskBoardStepStageBlock: View {
  let label: String
  let systemImage: String
  let text: String
  let tint: Color
  var emphasized = false

  @Environment(\.fontScale)
  private var fontScale

  private var labelFont: Font {
    HarnessMonitorTextSize.scaledFont(.caption.weight(.semibold), by: fontScale)
  }
  private var bodyFont: Font {
    HarnessMonitorTextSize.scaledFont(.callout, by: fontScale)
  }

  var body: some View {
    HStack(alignment: .top, spacing: HarnessMonitorTheme.spacingSM) {
      if emphasized {
        Capsule().fill(tint.opacity(0.55)).frame(width: 3)
      }
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
        Label(label, systemImage: systemImage)
          .font(labelFont)
          .foregroundStyle(tint)
        Text(text)
          .font(bodyFont)
          .foregroundStyle(.primary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
  }
}
