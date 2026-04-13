import SwiftUI
import HarnessMonitorKit

struct PersonaSymbolView: View {
  let symbol: PersonaSymbol
  var size: CGFloat = 24

  var body: some View {
    switch symbol {
    case .sfSymbol(let name):
      Image(systemName: name)
        .font(.system(size: size))
        .accessibilityLabel(name)
    case .asset(let name):
      Image(name, bundle: .main)
        .resizable()
        .scaledToFit()
        .frame(width: size, height: size)
        .accessibilityLabel(name)
    }
  }
}
