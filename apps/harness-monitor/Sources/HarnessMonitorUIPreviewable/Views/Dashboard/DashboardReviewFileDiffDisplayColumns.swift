import Foundation

/// Monospaced display-column width model for the soft-wrap engine.
///
/// Tabs are expanded to spaces before layout, so this only resolves the two
/// cases where a glyph is not one cell wide: East-Asian-wide and emoji
/// clusters render as two cells, combining and zero-width scalars render as
/// zero. Everything else is one column. Over-estimating an exotic cluster is
/// safe - it wraps a touch earlier and the draw layer clips, never bleeds.
enum DashboardReviewFileDiffDisplayColumns {
  /// Display columns occupied by a single grapheme cluster.
  static func width(of character: Character) -> Int {
    guard let scalar = character.unicodeScalars.first else { return 0 }
    if isZeroWidth(scalar) { return 0 }
    if isWide(scalar) { return 2 }
    return 1
  }

  /// Cumulative column widths where `result[i]` is the column count of the
  /// first `i` characters. `result.count == positions.count`, so the columns
  /// spanning offsets `a..<b` are `result[b] - result[a]`.
  static func prefixSums(text: String, positions: [String.Index]) -> [Int] {
    var sums = [Int](repeating: 0, count: positions.count)
    guard positions.count > 1 else { return sums }
    for index in 0..<(positions.count - 1) {
      sums[index + 1] = sums[index] + width(of: text[positions[index]])
    }
    return sums
  }

  private static func isZeroWidth(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x0000...0x001F, 0x007F:
      return true  // C0/C1 controls (already split out of rows by the parser)
    case 0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF:
      return true  // zero-width space/non-joiner/joiner/word-joiner/BOM
    case 0x0300...0x036F, 0x1AB0...0x1AFF, 0x1DC0...0x1DFF:
      return true  // combining diacritics
    case 0x20D0...0x20FF, 0xFE20...0xFE2F:
      return true  // combining marks for symbols / half marks
    case 0xFE00...0xFE0F, 0xE0100...0xE01EF:
      return true  // variation selectors
    default:
      return false
    }
  }

  private static func isWide(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x1100...0x115F:
      return true  // Hangul Jamo
    case 0x2329, 0x232A:
      return true  // angle brackets
    case 0x2E80...0x303E:
      return true  // CJK radicals, Kangxi, CJK symbols & punctuation
    case 0x3041...0x33FF:
      return true  // Hiragana, Katakana, CJK compatibility
    case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
      return true  // CJK Ext A, Unified, compatibility ideographs
    case 0xA000...0xA4CF:
      return true  // Yi syllables
    case 0xAC00...0xD7A3:
      return true  // Hangul syllables
    case 0xFE30...0xFE4F:
      return true  // CJK compatibility forms
    case 0xFF00...0xFF60, 0xFFE0...0xFFE6:
      return true  // Fullwidth forms and signs
    case 0x1F000...0x1FAFF, 0x2600...0x27BF:
      return true  // emoji, pictographs, misc symbols, dingbats
    case 0x20000...0x3FFFD:
      return true  // CJK Ext B and beyond
    default:
      return false
    }
  }
}
