import AppKit
import HarnessMonitorKit
import SwiftUI

extension OpenAnythingPaletteView {
  func jumpSection(by delta: Int) {
    let sections = navigableSections
    guard !sections.isEmpty else { return }
    let currentIndex = currentSectionIndex(sections: sections)
    let count = sections.count
    let nextIndex = ((currentIndex + delta) % count + count) % count
    if let firstHitID = sections[nextIndex].hits.first?.id {
      model.selectHit(id: firstHitID)
    }
  }

  func jumpToSection(index: Int) {
    let sections = navigableSections
    guard sections.indices.contains(index),
      let firstHitID = sections[index].hits.first?.id
    else { return }
    model.selectHit(id: firstHitID)
  }

  func currentSectionIndex(sections: [OpenAnythingSection]) -> Int {
    guard let selectedID = model.selectedHitID else { return 0 }
    for (index, section) in sections.enumerated()
    where section.hits.contains(where: { $0.id == selectedID }) {
      return index
    }
    return 0
  }

  private var navigableSections: [OpenAnythingSection] {
    model.displayedResults.sections.filter { section in
      !model.isCollapsed(sectionID: section.id) && !section.hits.isEmpty
    }
  }
}
