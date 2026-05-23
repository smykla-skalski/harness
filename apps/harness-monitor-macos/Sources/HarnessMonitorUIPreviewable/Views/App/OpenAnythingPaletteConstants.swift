import Foundation
import HarnessMonitorKit
import SwiftUI

/// Single source of truth for the Open Anything palette's layout, motion, and
/// debounce magic numbers. Co-locating them here keeps the palette view
/// readable and lets the redesign roll forward (or get tuned) without
/// scattering literal sizes across three files.
public enum OpenAnythingPaletteConstants {
  // Layout
  public static let topInset: CGFloat = 80
  public static let horizontalPadding: CGFloat = 32
  public static let maxWidth: CGFloat = 720
  public static let maxHeight: CGFloat = 560
  public static let resultsMaxHeight: CGFloat = 460
  public static let cornerRadius: CGFloat = 16
  public static let shadowRadius: CGFloat = 28
  public static let shadowYOffset: CGFloat = 16
  public static let shadowOpacity: Double = 0.25
  public static let scrimOpacity: Double = 0.22

  // Row metrics
  public static let rowIconColumnWidth: CGFloat = 24
  public static let rowVerticalPadding: CGFloat = 9
  public static let rowHorizontalPadding: CGFloat = 14
  public static let rowSpacing: CGFloat = 12
  public static let rowSelectedFillOpacity: Double = 0.16
  public static let rowHoverFillOpacity: Double = 0.06

  // Search field
  public static let searchFieldHorizontalPadding: CGFloat = 16
  public static let searchFieldVerticalPadding: CGFloat = 14
  public static let searchIconSize: CGFloat = 18

  // Section header
  public static let sectionHeaderHorizontalPadding: CGFloat = 14
  public static let sectionHeaderVerticalPadding: CGFloat = 6
  public static let sectionHeaderFillOpacity: Double = 0.08

  // Footer
  public static let footerHorizontalPadding: CGFloat = 14
  public static let footerVerticalPadding: CGFloat = 8

  // Optional preview pane
  /// When the host window is at least this wide, the palette renders a
  /// 280pt-wide preview pane on the right with the selected hit's expanded
  /// details. Narrower windows omit the pane and keep the original layout.
  public static let previewPaneActivationWidth: CGFloat = 980
  public static let previewPaneWidth: CGFloat = 280

  // Debounce
  /// 80 ms keeps a fast typist's "abc" from running three searches but stays
  /// short enough that a measured one-key tap still resolves before the user
  /// looks for results. Tune via this constant rather than at the call site.
  public static let searchDebounceNanoseconds: UInt64 = 80_000_000
}
