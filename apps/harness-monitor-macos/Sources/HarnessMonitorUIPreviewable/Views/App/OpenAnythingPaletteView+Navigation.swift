import AppKit
import HarnessMonitorKit
import SwiftUI

extension OpenAnythingPaletteView {
  func jumpSection(by delta: Int) {
    let sections = model.displayedResults.sections
    guard !sections.isEmpty else { return }
    let currentIndex = currentSectionIndex(sections: sections)
    let count = sections.count
    let nextIndex = ((currentIndex + delta) % count + count) % count
    if let firstHitID = sections[nextIndex].hits.first?.id {
      withAnimation(
        OpenAnythingMotionPolicy.selectionAnimation(reduceMotion: reduceMotion)
      ) {
        model.selectHit(id: firstHitID)
      }
    }
  }

  func jumpToSection(index: Int) {
    let sections = model.displayedResults.sections
    guard sections.indices.contains(index),
      let firstHitID = sections[index].hits.first?.id
    else { return }
    withAnimation(
      OpenAnythingMotionPolicy.selectionAnimation(reduceMotion: reduceMotion)
    ) {
      model.selectHit(id: firstHitID)
    }
  }

  func currentSectionIndex(sections: [OpenAnythingSection]) -> Int {
    guard let selectedID = model.selectedHitID else { return 0 }
    for (index, section) in sections.enumerated()
    where section.hits.contains(where: { $0.id == selectedID }) {
      return index
    }
    return 0
  }
}
