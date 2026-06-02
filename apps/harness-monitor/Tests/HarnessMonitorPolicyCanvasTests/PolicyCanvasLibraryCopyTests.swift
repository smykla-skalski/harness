import Foundation
import Testing

@testable import HarnessMonitorPolicyCanvas

@Suite("Policy library copy")
struct PolicyCanvasLibraryCopyTests {
  // Acronyms and product proper nouns allowed to keep their capitalization
  // anywhere in a title. `GitHub` and `Reviews` are product names; `PR`/`PRs`
  // are domain acronyms the policy library copy uses verbatim.
  private static let acronyms: Set<String> = [
    "OCR", "URL", "URLs", "PR", "PRs", "GitHub", "Reviews",
  ]

  private func isSentenceCase(_ text: String) -> Bool {
    let words = text.split(separator: " ").map(String.init)
    guard let first = words.first, leadingWordOK(first) else { return false }
    return words.dropFirst().allSatisfy(interiorWordOK)
  }

  private func leadingWordOK(_ word: String) -> Bool {
    if Self.acronyms.contains(word) { return true }
    guard let firstChar = word.first, firstChar.isUppercase else { return false }
    let rest = String(word.dropFirst())
    return rest == rest.lowercased()
  }

  private func interiorWordOK(_ word: String) -> Bool {
    Self.acronyms.contains(word) || word == word.lowercased()
  }

  @Test("node kind library titles are sentence case")
  func nodeKindLibraryTitles() {
    for kind in PolicyCanvasNodeKind.allCases {
      #expect(kind.libraryTitle.isEmpty == false)
      #expect(isSentenceCase(kind.libraryTitle), "not sentence case: \(kind.libraryTitle)")
    }
  }

  @Test("automation item library titles are sentence case")
  func automationLibraryTitles() {
    for item in PolicyCanvasAutomationPaletteItem.allCases {
      #expect(item.libraryTitle.isEmpty == false)
      #expect(isSentenceCase(item.libraryTitle), "not sentence case: \(item.libraryTitle)")
    }
  }

  @Test("library subtitles are sentence case and non-empty")
  func librarySubtitles() {
    for kind in PolicyCanvasNodeKind.allCases {
      #expect(kind.librarySubtitle.isEmpty == false)
      #expect(isSentenceCase(kind.librarySubtitle), "not sentence case: \(kind.librarySubtitle)")
    }
    for item in PolicyCanvasAutomationPaletteItem.allCases {
      #expect(item.librarySubtitle.isEmpty == false)
      #expect(isSentenceCase(item.librarySubtitle), "not sentence case: \(item.librarySubtitle)")
    }
  }

  @Test("library titles stay distinct from one another")
  func libraryTitlesDistinct() {
    let kindTitles = PolicyCanvasNodeKind.allCases.map(\.libraryTitle)
    let itemTitles = PolicyCanvasAutomationPaletteItem.allCases.map(\.libraryTitle)
    let titles = kindTitles + itemTitles
    #expect(Set(titles).count == titles.count)
  }
}
