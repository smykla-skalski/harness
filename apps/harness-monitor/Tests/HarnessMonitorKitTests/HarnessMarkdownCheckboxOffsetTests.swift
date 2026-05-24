import Foundation
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Harness markdown checkbox source offsets")
struct HarnessMarkdownCheckboxOffsetTests {
  @Test("Checkbox source offset points at the marker character")
  func checkboxSourceOffsetPointsAtMarker() {
    let body = "- [ ] alpha\n- [x] beta\n"
    let document = HarnessMarkdownParser.parse(body)
    guard case .unorderedList(let items) = document.blocks.first else {
      Issue.record("Expected unordered list")
      return
    }
    #expect(items.count == 2)
    #expect(items[0].checkbox == false)
    #expect(items[0].checkboxSourceOffset == 3)
    #expect(items[1].checkbox == true)
    #expect(items[1].checkboxSourceOffset == 15)
    let utf8 = Array(body.utf8)
    if let offset = items[0].checkboxSourceOffset {
      #expect(utf8[offset] == 0x20)
    }
    if let offset = items[1].checkboxSourceOffset {
      #expect(utf8[offset] == 0x78)
    }
  }

  @Test("Checkbox source offset accounts for indentation and tabs")
  func checkboxSourceOffsetAccountsForIndentation() {
    let body = "    - [x] indented\n\t- [ ] tabbed\n"
    let document = HarnessMarkdownParser.parse(body)
    guard case .unorderedList(let items) = document.blocks.first else {
      Issue.record("Expected unordered list")
      return
    }
    #expect(items.count == 2)
    #expect(items[0].checkboxSourceOffset == 7)
    #expect(items[1].checkboxSourceOffset == 23)
    let utf8 = Array(body.utf8)
    if let offset = items[0].checkboxSourceOffset {
      #expect(utf8[offset] == 0x78)
    }
    if let offset = items[1].checkboxSourceOffset {
      #expect(utf8[offset] == 0x20)
    }
  }

  @Test("Checkbox offsets survive multi-byte text on prior lines")
  func checkboxOffsetsSurviveMultiByteText() {
    let body = "Reno 🚀 status\n\n- [ ] rebase\n"
    let document = HarnessMarkdownParser.parse(body)
    let listBlock = document.blocks.first(where: { block in
      if case .unorderedList = block { return true }
      return false
    })
    guard case .unorderedList(let items) = listBlock else {
      Issue.record("Expected list block")
      return
    }
    guard let offset = items.first?.checkboxSourceOffset else {
      Issue.record("Expected checkbox offset")
      return
    }
    let utf8 = Array(body.utf8)
    #expect(utf8[offset] == 0x20)
    #expect(utf8[offset - 1] == 0x5B)
  }

  @Test("Nested checkbox inside list item carries source offset")
  func nestedCheckboxInsideListItemCarriesSourceOffset() {
    let body = "- [ ] outer\n  - [ ] inner\n"
    let document = HarnessMarkdownParser.parse(body)
    guard case .unorderedList(let outerItems) = document.blocks.first,
      let outer = outerItems.first
    else {
      Issue.record("Expected unordered list")
      return
    }
    #expect(outer.checkboxSourceOffset == 3)
    let nestedList = outer.blocks.first { block in
      if case .unorderedList = block { return true }
      return false
    }
    guard case .unorderedList(let innerItems) = nestedList,
      let inner = innerItems.first,
      let innerOffset = inner.checkboxSourceOffset
    else {
      Issue.record("Expected nested unordered list with checkbox offset")
      return
    }
    let utf8 = Array(body.utf8)
    #expect(utf8[innerOffset] == 0x20)
    #expect(utf8[innerOffset - 1] == 0x5B)
  }

  @Test("Nested checkbox under ordered list parent carries source offset")
  func nestedCheckboxUnderOrderedListCarriesSourceOffset() {
    let body = "1. outer\n  - [x] inner\n"
    let document = HarnessMarkdownParser.parse(body)
    guard case .orderedList(_, let outerItems) = document.blocks.first,
      let outer = outerItems.first
    else {
      Issue.record("Expected ordered list")
      return
    }
    let nestedList = outer.blocks.first { block in
      if case .unorderedList = block { return true }
      return false
    }
    guard case .unorderedList(let innerItems) = nestedList,
      let inner = innerItems.first,
      let innerOffset = inner.checkboxSourceOffset
    else {
      Issue.record("Expected nested unordered list with checkbox offset")
      return
    }
    let utf8 = Array(body.utf8)
    #expect(utf8[innerOffset] == 0x78)
    #expect(utf8[innerOffset - 1] == 0x5B)
  }

  @Test("Plain bullets and ordered items carry no checkbox offset")
  func nonCheckboxItemsCarryNoOffset() {
    let document = HarnessMarkdownParser.parse(
      """
      - plain
      1. ordered
      """
    )
    guard case .unorderedList(let unordered) = document.blocks[0],
      case .orderedList(_, let ordered) = document.blocks[1]
    else {
      Issue.record("Expected unordered then ordered list")
      return
    }
    #expect(unordered.first?.checkbox == nil)
    #expect(unordered.first?.checkboxSourceOffset == nil)
    #expect(ordered.first?.checkbox == nil)
    #expect(ordered.first?.checkboxSourceOffset == nil)
  }
}
