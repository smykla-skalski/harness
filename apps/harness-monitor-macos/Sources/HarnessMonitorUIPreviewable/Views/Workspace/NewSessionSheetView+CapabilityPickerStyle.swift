import SwiftUI

extension View {
  func newSessionProviderCard(tint: Color) -> some View {
    self
      .padding(HarnessMonitorTheme.cardPadding)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusMD, style: .continuous)
          .fill(tint.opacity(0.08))
      )
      .overlay {
        RoundedRectangle(cornerRadius: HarnessMonitorTheme.cornerRadiusMD, style: .continuous)
          .stroke(tint.opacity(0.18), lineWidth: 1)
      }
  }
}
