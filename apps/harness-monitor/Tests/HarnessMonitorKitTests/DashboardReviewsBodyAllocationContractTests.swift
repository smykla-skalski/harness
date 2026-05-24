import Testing

@Suite("Dashboard reviews body allocation contracts")
struct DashboardReviewsBodyAllocationContractTests {
  @Test("body paths avoid transient ForEach arrays")
  func bodyPathsAvoidTransientForEachArrays() throws {
    let files = [
      "DashboardReviewCheckList.swift",
      "DashboardReviewFilesSection.swift",
      "DashboardReviewsLabelPicker.swift",
      "DashboardReviewsProvenance+Popover.swift",
      "DashboardReviewsReviewLabelLists.swift",
    ]

    for file in files {
      let source = try dashboardReviewsRouteSource(named: file)
      #expect(!source.contains("ForEach(Array("))
    }
  }

  @Test("dynamic body lists use element identity instead of offsets")
  func dynamicBodyListsUseElementIdentity() throws {
    let labelPickerSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewsLabelPicker.swift"
    )
    let provenanceSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewsProvenance+Popover.swift"
    )
    let reviewLabelsSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewsReviewLabelLists.swift"
    )

    #expect(!labelPickerSource.contains("ForEach(groups.indices"))
    #expect(!provenanceSource.contains("ForEach(snapshot.warnings.indices"))
    #expect(!reviewLabelsSource.contains("ForEach(reviews.indices"))
  }
}
