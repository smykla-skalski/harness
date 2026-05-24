import Testing

@Suite("Dashboard reviews presentation task identity")
struct DashboardReviewsPresentationTaskIDTests {
  @Test("route presentation task identity stays lightweight")
  func routePresentationTaskIdentityStaysLightweight() throws {
    let routeSource = try dashboardReviewsRouteSource()
    let modelsSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewsPresentationModels.swift")

    #expect(routeSource.contains("var presentationTaskID: DashboardReviewsPresentationTaskID"))
    #expect(
      routeSource.contains("var listPresentationInput: DashboardReviewsListPresentationInput"))
    #expect(routeSource.contains(".task(id: presentationTaskID)"))
    #expect(routeSource.contains("await rebuildPresentation(input: listPresentationInput)"))
    #expect(!routeSource.contains(".task(id: presentationInput)"))
    #expect(modelsSource.contains("struct DashboardReviewsPresentationTaskID"))
    #expect(modelsSource.contains("let preferencesSignature: String"))
    let taskSource = sourceSlice(
      modelsSource,
      from: "struct DashboardReviewsPresentationTaskID",
      to: "struct DashboardReviewsPresentationSelectionID"
    )
    #expect(!taskSource.contains("selectedIDs"))
    #expect(!taskSource.contains("persistedPrimarySelectionID"))
    #expect(
      !modelsSource.contains(
        "struct DashboardReviewsPresentationTaskID: Equatable, Sendable {\n  let items: [ReviewItem]"
      ))
  }

  @Test("route applies selection changes outside the list presentation task")
  func routeAppliesSelectionChangesOutsideTheListPresentationTask() throws {
    let routeSource = try dashboardReviewsRouteSource()
    let actionSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewsRouteView+Actions.swift")
    let modelsSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewsPresentationModels.swift")
    let selectionSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewsPresentationSelection.swift")

    #expect(
      routeSource.contains("var presentationSelectionID: DashboardReviewsPresentationSelectionID"))
    #expect(routeSource.contains(".onChange(of: presentationSelectionID, initial: true)"))
    #expect(actionSource.contains("func refreshCachedPresentationSelection()"))
    #expect(actionSource.contains("routeCachedPresentation.applyingSelection("))
    #expect(actionSource.contains("routePresentationWorker.computeList(input: input)"))
    #expect(modelsSource.contains("struct DashboardReviewsPresentationSelectionID"))
    #expect(selectionSource.contains("func applyingSelection("))
  }

  @Test("route response metadata updates do not invalidate list presentation")
  func routeResponseMetadataUpdatesDoNotInvalidateListPresentation() throws {
    let accessorsSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewsRouteView+Accessors.swift")
    let cacheSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewsRouteView+Cache.swift")
    let schedulerSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewsRouteView+Scheduler.swift")
    let refreshSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewsRouteView+Refresh.swift")

    #expect(accessorsSource.contains("func setRouteResponse("))
    #expect(accessorsSource.contains("if bumpsItemsRevision {"))
    #expect(cacheSource.contains("setRouteResponse(response, bumpsItemsRevision: false)"))
    #expect(schedulerSource.contains("let itemsChanged = nextItems != currentResponse.items"))
    #expect(
      schedulerSource.contains(
        "setRouteResponse(response, bumpsItemsRevision: itemsChanged)"
      )
    )
    #expect(refreshSource.contains("let itemsChanged = nextItems != currentResponse.items"))
    #expect(
      refreshSource.contains(
        "setRouteResponse(response, bumpsItemsRevision: itemsChanged)"
      )
    )
  }
}

private func sourceSlice(_ source: String, from start: String, to end: String) -> String {
  guard let startRange = source.range(of: start) else { return "" }
  let remainder = source[startRange.lowerBound...]
  guard let endRange = remainder.range(of: end) else { return String(remainder) }
  return String(remainder[..<endRange.lowerBound])
}
