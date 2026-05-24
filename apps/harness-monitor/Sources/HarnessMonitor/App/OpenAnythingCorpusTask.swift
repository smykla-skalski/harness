import HarnessMonitorKit

enum OpenAnythingCorpusTask {
  static func sourceSignature(input: OpenAnythingCorpusInput) async -> Int {
    await withTaskGroup(of: Int.self) { group in
      group.addTask(priority: .utility) {
        OpenAnythingCorpusSourceSignature.compute(input)
      }
      return await group.next() ?? 0
    }
  }

  static func records(input: OpenAnythingCorpusInput) async -> [OpenAnythingRecord] {
    await withTaskGroup(of: [OpenAnythingRecord].self) { group in
      group.addTask(priority: .utility) {
        OpenAnythingCorpusBuilder.records(input: input)
      }
      return await group.next() ?? []
    }
  }

  static func signature(records: [OpenAnythingRecord], fallback sourceSignature: Int) async
    -> Int
  {
    guard OpenAnythingPluginRegistry.shared.hasRegisteredPlugins else {
      return sourceSignature
    }
    return await withTaskGroup(of: Int.self) { group in
      group.addTask(priority: .utility) {
        OpenAnythingCorpusSignature.compute(records)
      }
      return await group.next() ?? sourceSignature
    }
  }
}
