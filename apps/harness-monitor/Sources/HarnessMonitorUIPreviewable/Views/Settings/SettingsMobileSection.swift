import SwiftUI

public struct SettingsMobileSection: View {
  public let pairingContent: (@MainActor @Sendable () -> AnyView)?
  public let isActive: Bool

  public init(
    pairingContent: (@MainActor @Sendable () -> AnyView)? = nil,
    isActive: Bool = true
  ) {
    self.pairingContent = pairingContent
    self.isActive = isActive
  }

  public var body: some View {
    if isActive {
      activeBody
    } else {
      Color.clear
    }
  }

  private var activeBody: some View {
    Form {
      Section {
        VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
          Label("Pair iPhone or Apple Watch", systemImage: "qrcode.viewfinder")
            .scaledFont(.headline)
          Text(
            "Scan the QR code from Harness Monitor on iPhone to create an encrypted relay pair for this Mac."
          )
          .scaledFont(.subheadline)
          .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      } header: {
        Text("Mobile Pairing")
          .harnessNativeFormSectionHeader()
      }

      Section {
        if let pairingContent {
          pairingContent()
        } else {
          Label(
            "Mobile relay is not available in this app mode.",
            systemImage: "iphone.slash"
          )
          .scaledFont(.body)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      } header: {
        Text("Pairing Code")
          .harnessNativeFormSectionHeader()
      }
    }
    .settingsDetailFormStyle()
    .accessibilityIdentifier(HarnessMonitorAccessibility.settingsMobileSection)
  }
}
