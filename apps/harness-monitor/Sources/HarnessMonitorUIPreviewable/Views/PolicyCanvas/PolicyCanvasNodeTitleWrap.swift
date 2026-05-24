import Foundation

/// Pre-processes node titles for the fixed-width 168pt node card so SwiftUI
/// breaks on identifier separators (`:` and `_`) and never hyphenates inside
/// a letter run. Without this, titles like `supervisor:merge-deny` and
/// `dry_run:mutate_repo` wrapped as `supervi-`/`sor:merge-deny` and
/// `dry_run:mu-`/`tate_repo` because the layout engine picked
/// character-level breaks when `.lineLimit(2)` + `.minimumScaleFactor(0.7)`
/// could not fit the string at any scale.
///
/// Strategy: insert a Unicode zero-width space (U+200B) after every `:` and
/// `_`. ZWSP is honored by CoreText as a soft break opportunity, is
/// invisible when no break occurs, and does not appear in screen-reader
/// output. Combined with `.truncationMode(.middle)` at the call site, the
/// long-identifier fallback truncates as `supervisor:…merge-deny` rather
/// than losing either side.
enum PolicyCanvasNodeTitleWrap {
  static let breakHint: Character = "\u{200B}"

  static func wrapSafe(_ raw: String) -> String {
    guard raw.contains(where: { $0 == ":" || $0 == "_" }) else {
      return raw
    }
    var out = ""
    out.reserveCapacity(raw.count + raw.count / 4)
    let characters = Array(raw)
    for index in characters.indices {
      let character = characters[index]
      out.append(character)
      guard character == ":" || character == "_" else {
        continue
      }
      let next = index + 1 < characters.count ? characters[index + 1] : nil
      if next != breakHint {
        out.append(breakHint)
      }
    }
    return out
  }
}
