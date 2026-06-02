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
}
