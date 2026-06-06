import AppKit
import Foundation
import HarnessMonitorKit
import SwiftUI

extension DashboardReviewListRow {
  // MARK: - Row chrome

  var usesSelectedBackgroundContrast: Bool {
    isSelected
  }

  var primaryTextColor: Color {
    if usesSelectedBackgroundContrast {
      Color(nsColor: .alternateSelectedControlTextColor)
    } else {
      HarnessMonitorTheme.ink
    }
  }

  var secondaryTextColor: Color {
    if usesSelectedBackgroundContrast {
      Color(nsColor: .alternateSelectedControlTextColor)
    } else {
      HarnessMonitorTheme.secondaryInk
    }
  }

  var statusIndicatorColor: Color {
    if usesSelectedBackgroundContrast {
      Color(nsColor: .alternateSelectedControlTextColor)
    } else {
      item.statusTint
    }
  }

  var selectedIconDimmedOpacity: Double {
    usesSelectedBackgroundContrast ? 0.74 : 0.4
  }

  /// Draft pull requests no longer carry a separate Draft pill; the title reads
  /// as de-emphasized instead. `ink` and the selected-row white are both
  /// dynamic, so dimming with opacity stays correct in light and dark. The
  /// selected variant dims less to keep the title legible on the accent fill.
  var draftTitleOpacity: Double {
    guard item.isDraft else { return 1 }
    return usesSelectedBackgroundContrast ? 0.72 : 0.5
  }
}
