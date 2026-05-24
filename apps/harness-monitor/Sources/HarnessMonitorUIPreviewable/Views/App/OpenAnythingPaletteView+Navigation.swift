import AppKit
import HarnessMonitorKit
import SwiftUI

extension OpenAnythingPaletteView {
  func jumpSection(by delta: Int) {
    guard
      let firstHitID = model.displayedResults.firstHitIDInVisibleSection(
        movingFrom: model.selectedHitID,
        bySection: delta,
        excludingCollapsedSections: model.collapsedSections
      )
    else { return }
    model.selectHit(id: firstHitID)
  }

  func jumpToSection(index: Int) {
    guard
      let firstHitID = model.displayedResults.firstHitIDInVisibleSection(
        at: index,
        excludingCollapsedSections: model.collapsedSections
      )
    else { return }
    model.selectHit(id: firstHitID)
  }
}
