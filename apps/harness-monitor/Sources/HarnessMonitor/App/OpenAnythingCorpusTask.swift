import HarnessMonitorKit

enum OpenAnythingCorpusTask {
  static func sourceSignature(input: OpenAnythingCorpusInput) -> Int {
    OpenAnythingCorpusSourceSignature.compute(input)
  }

  static func records(input: OpenAnythingCorpusInput) -> [OpenAnythingRecord] {
    OpenAnythingCorpusBuilder.records(input: input)
  }

  static func signature(records: [OpenAnythingRecord], fallback sourceSignature: Int) -> Int {
    guard OpenAnythingPluginRegistry.shared.hasRegisteredPlugins else {
      return sourceSignature
    }
    return OpenAnythingCorpusSignature.compute(records)
  }
}
