import Testing

@testable import HarnessMonitorUIPreviewable

@MainActor
extension TaskBoardOverviewBehaviorTests {
  @Test("Lane metrics scale pill padding with font scale")
  func laneMetricsScalePillPaddingWithFontScale() {
    let regular = TaskBoardLaneMetrics(fontScale: 1)
    let large = TaskBoardLaneMetrics(fontScale: 1.8)

    #expect(large.pillHorizontalPadding > regular.pillHorizontalPadding)
    #expect(large.pillVerticalPadding > regular.pillVerticalPadding)
  }

  @Test("Lane metrics expose a rounded top accent cap")
  func laneMetricsExposeRoundedTopAccentCap() {
    let metrics = TaskBoardLaneMetrics(fontScale: 1)

    #expect(metrics.laneAccentHeight == 8)
    #expect(metrics.laneAccentVisibleHeight == 4)
    #expect(metrics.laneAccentCornerRadius == metrics.laneAccentHeight)
    #expect(metrics.laneAccentInteriorCornerRadius == metrics.laneAccentHeight)
  }

  @Test("Lane metrics expose collapsed rail geometry")
  func laneMetricsExposeCollapsedRailGeometry() {
    let metrics = TaskBoardLaneMetrics(fontScale: 1)

    #expect(metrics.laneCollapsedWidth == 72)
    #expect(metrics.laneCollapsedWidth < metrics.laneWidth)
    #expect(metrics.laneCollapsedBadgeSize > 0)
    #expect(metrics.laneCollapsedTitleHeight > metrics.laneCollapsedWidth)
  }

  @Test("Lane metrics align header body gap with side inset")
  func laneMetricsAlignHeaderBodyGapWithSideInset() {
    let regular = TaskBoardLaneMetrics(fontScale: 1)
    let large = TaskBoardLaneMetrics(fontScale: 1.8)

    #expect(
      abs(
        regular.headerBottomPadding + regular.laneHeaderBodyTopPadding - regular.laneInnerPadding
      ) < 0.001
    )
    #expect(
      abs(
        large.headerBottomPadding + large.laneHeaderBodyTopPadding - large.laneInnerPadding
      ) < 0.001
    )
  }

  @Test("Lane List row inset accounts for the native macOS section margin")
  func laneListRowInsetAlignsCardsWithHeader() {
    let regular = TaskBoardLaneMetrics(fontScale: 1)
    let large = TaskBoardLaneMetrics(fontScale: 1.8)

    #expect(
      abs(
        regular.listRowHorizontalInset + HarnessMonitorTheme.spacingSM
          - regular.laneInnerPadding
      ) < 0.001
    )
    #expect(
      abs(
        large.listRowHorizontalInset + HarnessMonitorTheme.spacingSM
          - large.laneInnerPadding
      ) < 0.001
    )
  }

  @Test("Overview metrics share scaled board spacing and padding")
  func overviewMetricsShareScaledBoardSpacingAndPadding() {
    let regular = TaskBoardOverviewMetrics(fontScale: 1)
    let large = TaskBoardOverviewMetrics(fontScale: 1.8)

    #expect(regular.operationsCardMinWidth == 300)
    #expect(large.operationsCardMinWidth > regular.operationsCardMinWidth)
    #expect(large.operationsCardMaxWidth > regular.operationsCardMaxWidth)
    #expect(large.columnSpacing > regular.columnSpacing)
    #expect(large.boardVerticalPadding > regular.boardVerticalPadding)
    #expect(large.summaryPillHorizontalPadding > regular.summaryPillHorizontalPadding)
    #expect(large.summaryPillVerticalPadding > regular.summaryPillVerticalPadding)
  }
}
