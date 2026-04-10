import SwiftUI

struct SidebarRecentSearchesView: View {
  let queries: [String]
  let isPersistenceAvailable: Bool
  let applyQuery: (String) -> Void
  let clearHistory: () -> Void
  @Environment(\.fontScale)
  private var fontScale

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingXS) {
      HStack {
        Text("Recent Searches")
          .font(scaled(.caption.bold()))
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)

        Spacer()

        if isPersistenceAvailable {
          Button("Clear", action: clearHistory)
            .harnessDismissButtonStyle()
            .font(scaled(.caption))
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
            .accessibilityIdentifier(HarnessMonitorAccessibility.sidebarClearSearchHistoryButton)
        }
      }

      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: HarnessMonitorTheme.spacingXS) {
          ForEach(queries, id: \.self) { query in
            Button {
              applyQuery(query)
            } label: {
              Text(query)
                .lineLimit(1)
                .padding(.horizontal, HarnessMonitorTheme.spacingSM)
                .padding(.vertical, HarnessMonitorTheme.spacingXS)
            }
            .harnessAccessoryButtonStyle()
          }
        }
      }
    }
  }

  private func scaled(_ font: Font) -> Font {
    HarnessMonitorTextSize.scaledFont(font, by: fontScale)
  }
}
