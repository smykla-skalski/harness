import Testing

@Suite("Dashboard reviews presentation task identity")
struct DashboardReviewsPresentationTaskIDTests {
  @Test("route presentation task identity stays lightweight")
  func routePresentationTaskIdentityStaysLightweight() throws {
    let routeSource = try dashboardReviewsRouteSource()
    let modelsSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewsPresentationModels.swift")

    #expect(routeSource.contains("var presentationTaskID: DashboardReviewsPresentationTaskID"))
    #expect(routeSource.contains(".task(id: presentationTaskID)"))
    #expect(!routeSource.contains(".task(id: presentationInput)"))
    #expect(modelsSource.contains("struct DashboardReviewsPresentationTaskID"))
    #expect(modelsSource.contains("let preferencesSignature: String"))
    #expect(
      !modelsSource.contains(
        "struct DashboardReviewsPresentationTaskID: Equatable, Sendable {\n  let items: [ReviewItem]"
      ))
  }
}
