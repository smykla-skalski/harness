import Testing

extension DashboardReviewsBodyAllocationContractTests {
  @Test("review files ingest avoids transient path arrays")
  func reviewFilesIngestAvoidsTransientPathArrays() throws {
    let viewModelSource = try dashboardReviewsAppSource(
      "apps/harness-monitor/Sources/HarnessMonitorKit/Models/ReviewFilesViewModel.swift"
    )
    let treeBuilderSource = try dashboardReviewsAppSource(
      "apps/harness-monitor/Sources/HarnessMonitorKit/Models/ReviewFileTreeBuilder.swift"
    )

    #expect(viewModelSource.contains("private func rebuildFileIndexes"))
    #expect(viewModelSource.contains("nextFilesByPath.reserveCapacity(files.count)"))
    #expect(viewModelSource.contains("nextFilteredPathSet.reserveCapacity(sortedFiles.count)"))
    #expect(treeBuilderSource.contains("private static func skipSlashes"))
    #expect(!viewModelSource.contains("response.files.map"))
    #expect(!viewModelSource.contains("Set(response.files.map"))
    #expect(!viewModelSource.contains("filteredFiles.map(\\.path)"))
    #expect(!viewModelSource.contains("filteredPathSet = Self.pathSet(for: filteredFiles)"))
    #expect(!treeBuilderSource.contains("path.split(separator: \"/\").map(String.init)"))
  }
}
