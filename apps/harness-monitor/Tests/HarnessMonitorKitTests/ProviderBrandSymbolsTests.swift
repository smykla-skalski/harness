import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Provider and brand symbols")
struct ProviderBrandSymbolsTests {
  @Test("Renovate is exposed as a brand asset, not a runtime provider")
  func renovateIsExposedAsBrandAssetNotRuntimeProvider() {
    #expect(ProviderBrandSymbol.allCases.contains(.renovate))
    #expect(ProviderBrandSymbol.renovate.assetName == "BrandSymbol-renovate")
    #expect(ProviderBrandSymbol(runtimeString: "renovate") == nil)
  }

  @Test("Dependabot is exposed as a brand asset, not a runtime provider")
  func dependabotIsExposedAsBrandAssetNotRuntimeProvider() {
    #expect(ProviderBrandSymbol.allCases.contains(.dependabot))
    #expect(ProviderBrandSymbol.dependabot.assetName == "BrandSymbol-dependabot")
    #expect(ProviderBrandSymbol(runtimeString: "dependabot") == nil)
  }
}
