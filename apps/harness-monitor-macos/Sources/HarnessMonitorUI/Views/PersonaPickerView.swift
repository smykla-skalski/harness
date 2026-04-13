import SwiftUI
import HarnessMonitorKit

struct PersonaPickerView: View {
  let personas: [AgentPersona]
  let onSelect: (String?) -> Void

  @State private var expandedInfo: String?

  private let columns = [GridItem(.adaptive(minimum: 140), spacing: HarnessMonitorTheme.spacingMD)]

  var body: some View {
    VStack(spacing: HarnessMonitorTheme.spacingLG) {
      Text("Choose a persona")
        .scaledFont(.title2.bold())

      LazyVGrid(columns: columns, spacing: HarnessMonitorTheme.spacingMD) {
        ForEach(personas, id: \.identifier) { persona in
          personaCard(persona)
        }

        skipCard
      }
      .accessibilityIdentifier("harness.agent-tui.persona-picker")
    }
    .padding(HarnessMonitorTheme.spacingLG)
  }

  private func personaCard(_ persona: AgentPersona) -> some View {
    Button {
      onSelect(persona.identifier)
    } label: {
      VStack(spacing: HarnessMonitorTheme.spacingSM) {
        PersonaSymbolView(symbol: persona.symbol, size: 40)
          .foregroundStyle(HarnessMonitorTheme.accent)

        Text(persona.name)
          .scaledFont(.callout.weight(.medium))
          .lineLimit(2)
          .multilineTextAlignment(.center)
      }
      .frame(minWidth: 120, minHeight: 100)
      .frame(maxWidth: .infinity)
    }
    .harnessInteractiveCardButtonStyle()
    .accessibilityIdentifier("harness.agent-tui.persona.\(persona.identifier)")
    .accessibilityLabel(persona.name)
    .popover(isPresented: Binding(
      get: { expandedInfo == persona.identifier },
      set: { if !$0 { expandedInfo = nil } }
    )) {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.spacingSM) {
        Text(persona.name)
          .scaledFont(.headline)
        Text(persona.description)
          .scaledFont(.body)
          .foregroundStyle(.secondary)
      }
      .padding()
      .frame(maxWidth: 280)
    }
    .contextMenu {
      Button("Learn more") {
        expandedInfo = persona.identifier
      }
    }
  }

  private var skipCard: some View {
    Button {
      onSelect(nil)
    } label: {
      VStack(spacing: HarnessMonitorTheme.spacingSM) {
        Image(systemName: "arrow.right.circle")
          .font(.system(size: 40))
          .foregroundStyle(.secondary)

        Text("Skip")
          .scaledFont(.callout.weight(.medium))
          .foregroundStyle(.secondary)
      }
      .frame(minWidth: 120, minHeight: 100)
      .frame(maxWidth: .infinity)
    }
    .harnessInteractiveCardButtonStyle()
    .accessibilityIdentifier("harness.agent-tui.persona.skip")
    .accessibilityLabel("Skip persona selection")
  }
}
