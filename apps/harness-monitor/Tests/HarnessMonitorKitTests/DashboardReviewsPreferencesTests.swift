import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Dashboard dependencies preferences")
struct DashboardReviewsPreferencesTests {
  @Test("default initializer produces the documented defaults")
  func defaultsMatchDocumentation() {
    let prefs = DashboardReviewsPreferences()
    #expect(prefs.refreshIntervalSeconds == 300)
    #expect(prefs.perRepositoryIntervalSeconds == 300)
    #expect(prefs.maxConcurrentRepositoryFetches == 2)
    #expect(prefs.expandOrganizations)
    #expect(prefs.preferredGroupModeRaw == DashboardReviewsGroupMode.repository.rawValue)
    #expect(prefs.filesGeneratedPatterns == DashboardReviewsPreferences.defaultGeneratedPatterns)
    #expect(prefs.filesGeneratedPatterns.contains("**/vendor/**"))
    #expect(prefs.filesGeneratedPatterns.contains("**/*.generated.swift"))
    #expect(prefs.filesSoftWrapEnabled)
    #expect(prefs.filesTabWidth == 8)
    #expect(prefs.filesTabWidth == DashboardReviewsPreferences.defaultFilesTabWidth)
    #expect(!prefs.showActivityInlineComments)
    #expect(!prefs.showApprovalCountsInRows)
    #expect(prefs.showTargetBranchInRows)
    #expect(prefs.backportDetectionEnabled)
    #expect(prefs.normalizedBackportPatterns == DashboardReviewsPreferences.defaultBackportPatterns)
  }

  @Test("legacy stored preferences migrate the polling interval into the per-repo field")
  func legacyIntervalMigratesIntoPerRepoField() throws {
    let legacy = """
      {
        "authorsText": "renovate[bot]",
        "refreshIntervalSeconds": 900
      }
      """
    let prefs = DashboardReviewsPreferences.decode(from: legacy)
    #expect(prefs.refreshIntervalSeconds == 900)
    #expect(
      prefs.perRepositoryIntervalSeconds == 900,
      "missing perRepositoryIntervalSeconds must fall back to refreshIntervalSeconds"
    )
    #expect(prefs.maxConcurrentRepositoryFetches == 2)
    #expect(prefs.expandOrganizations)
  }

  @Test("explicit per-repo interval wins over legacy refreshIntervalSeconds")
  func explicitPerRepoIntervalWins() throws {
    let payload = """
      {
        "refreshIntervalSeconds": 900,
        "perRepositoryIntervalSeconds": 120,
        "maxConcurrentRepositoryFetches": 4,
        "expandOrganizations": false
      }
      """
    let prefs = DashboardReviewsPreferences.decode(from: payload)
    #expect(prefs.refreshIntervalSeconds == 900)
    #expect(prefs.perRepositoryIntervalSeconds == 120)
    #expect(prefs.maxConcurrentRepositoryFetches == 4)
    #expect(!prefs.expandOrganizations)
  }

  @Test("normalized clamps interval and concurrency into safe bounds")
  func normalizedClampsBounds() {
    var prefs = DashboardReviewsPreferences()
    prefs.perRepositoryIntervalSeconds = 5
    prefs.maxConcurrentRepositoryFetches = 0
    let lowClamped = prefs.normalized()
    #expect(
      lowClamped.perRepositoryIntervalSeconds
        == DashboardReviewsPreferences.minimumPerRepositoryIntervalSeconds
    )
    #expect(
      lowClamped.maxConcurrentRepositoryFetches
        == DashboardReviewsPreferences.minimumConcurrentRepositoryFetches
    )

    prefs.perRepositoryIntervalSeconds = 10_000
    prefs.maxConcurrentRepositoryFetches = 99
    let highClamped = prefs.normalized()
    #expect(
      highClamped.perRepositoryIntervalSeconds
        == DashboardReviewsPreferences.maximumPerRepositoryIntervalSeconds
    )
    #expect(
      highClamped.maxConcurrentRepositoryFetches
        == DashboardReviewsPreferences.maximumConcurrentRepositoryFetches
    )
  }

  @Test("per-repo query request scopes to a single repository and strips orgs")
  func perRepositoryRequestShape() {
    var prefs = DashboardReviewsPreferences()
    prefs.authorsText = "renovate[bot], dependabot[bot]"
    prefs.organizationsText = "acme, contoso"
    prefs.repositoriesText = "acme/api, acme/web"
    prefs.excludeRepositoriesText = "acme/legacy"

    let request = prefs.perRepositoryQueryRequest(for: "acme/web", forceRefresh: true)
    #expect(request.repositories == ["acme/web"])
    #expect(request.organizations.isEmpty)
    #expect(request.excludeRepositories == ["acme/legacy"])
    #expect(request.authors.sorted() == ["dependabot[bot]", "renovate[bot]"].sorted())
    #expect(request.forceRefresh)
    #expect(request.backportDetectionEnabled)
    #expect(request.backportPatterns == DashboardReviewsPreferences.defaultBackportPatterns)
  }

  @Test("backport regex settings normalize and flow into query requests")
  func backportRegexSettingsNormalizeAndFlowIntoQueries() {
    var prefs = DashboardReviewsPreferences()
    prefs.repositoriesText = "acme/api"
    prefs.backportDetectionEnabled = false
    prefs.backportPatternsText = """

      (?i)\\s*\\(backport of #(?P<number>\\d+)\\)\\s*$
      (?i)\\s*\\(backport of #(?P<number>\\d+)\\)\\s*$
      (?i)\\s*\\[picked from #(?P<number>\\d+)\\]\\s*$
      """

    let normalized = prefs.normalized()
    let request = normalized.queryRequest(forceRefresh: false)

    #expect(
      normalized.backportPatternsText
        == """
        (?i)\\s*\\(backport of #(?P<number>\\d+)\\)\\s*$
        (?i)\\s*\\[picked from #(?P<number>\\d+)\\]\\s*$
        """
    )
    #expect(!request.backportDetectionEnabled)
    #expect(request.backportPatterns == normalized.normalizedBackportPatterns)
  }

  @Test("legacy authorsText defaulting to renovate[bot] clears on decode")
  func legacyRenovateBotAuthorsClears() {
    let legacy = """
      {
        "authorsText": "renovate[bot]",
        "organizationsText": "acme"
      }
      """
    let prefs = DashboardReviewsPreferences.decode(from: legacy)
    #expect(prefs.authorsText.isEmpty)
    #expect(prefs.normalizedAuthors.isEmpty)
    #expect(prefs.organizationsText == "acme")
  }

  @Test("legacy authorsText with whitespace-wrapped renovate bot still clears on decode")
  func legacyRenovateBotAuthorsWithWhitespaceClears() {
    let legacy = """
      {
        "authorsText": "  renovate[bot]  \\n",
        "organizationsText": "acme"
      }
      """
    let prefs = DashboardReviewsPreferences.decode(from: legacy)
    #expect(prefs.authorsText.isEmpty)
    #expect(prefs.normalizedAuthors.isEmpty)
    #expect(prefs.organizationsText == "acme")
  }

  @Test("user-customized authorsText survives decode untouched")
  func userCustomizedAuthorsSurvives() {
    let payload = """
      {
        "authorsText": "renovate[bot], dependabot[bot]"
      }
      """
    let prefs = DashboardReviewsPreferences.decode(from: payload)
    #expect(prefs.authorsText == "renovate[bot], dependabot[bot]")
  }

  @Test("legacy renovate[bot] blob produces a queryRequest with no authors")
  func legacyBlobProducesQueryRequestWithoutAuthors() {
    let legacy = """
      {
        "authorsText": "renovate[bot]",
        "organizationsText": "acme"
      }
      """
    let prefs = DashboardReviewsPreferences.decode(from: legacy)
    let request = prefs.queryRequest(forceRefresh: false)
    #expect(request.authors.isEmpty)
    #expect(request.organizations == ["acme"])
  }

  @Test("legacy generated regex defaults migrate to glob defaults")
  func legacyGeneratedRegexDefaultsMigrateToGlobs() throws {
    let payloadData = try JSONSerialization.data(
      withJSONObject: [
        "filesGeneratedPatterns": DashboardReviewsPreferences.legacyDefaultGeneratedPatterns
      ]
    )
    let payload = try #require(String(data: payloadData, encoding: .utf8))

    let prefs = DashboardReviewsPreferences.decode(from: payload)

    #expect(prefs.filesGeneratedPatterns == DashboardReviewsPreferences.defaultGeneratedPatterns)
  }

  @Test("normalized generated patterns trim blanks and remove duplicates")
  func normalizedGeneratedPatternsTrimAndDeduplicate() {
    var prefs = DashboardReviewsPreferences()
    prefs.filesGeneratedPatterns = [
      "  **/*.generated.swift  ",
      "",
      "**/*.generated.swift",
      "package-lock.json",
    ]

    let normalized = prefs.normalized()

    #expect(
      normalized.filesGeneratedPatterns == [
        "**/*.generated.swift",
        "package-lock.json",
      ]
    )
  }

  @Test("re-encoding new preferences round-trips through Codable")
  func encodingRoundTripsNewFields() throws {
    var prefs = DashboardReviewsPreferences()
    prefs.perRepositoryIntervalSeconds = 180
    prefs.maxConcurrentRepositoryFetches = 5
    prefs.expandOrganizations = false
    prefs.preferredGroupModeRaw = DashboardReviewsGroupMode.smartInbox.rawValue
    prefs.filesDefaultViewModeRaw = FilesViewMode.split.rawValue
    prefs.filesSoftWrapEnabled = false
    prefs.showApprovalCountsInRows = true
    prefs.showTargetBranchInRows = false
    prefs.showActivityInlineComments = true

    let encoded = prefs.encodedString
    let decoded = DashboardReviewsPreferences.decode(from: encoded)
    #expect(decoded.perRepositoryIntervalSeconds == 180)
    #expect(decoded.maxConcurrentRepositoryFetches == 5)
    #expect(!decoded.expandOrganizations)
    #expect(decoded.preferredGroupModeRaw == DashboardReviewsGroupMode.smartInbox.rawValue)
    #expect(decoded.filesDefaultViewMode == .split)
    #expect(!decoded.filesSoftWrapEnabled)
    #expect(decoded.showApprovalCountsInRows)
    #expect(!decoded.showTargetBranchInRows)
    #expect(decoded.showActivityInlineComments)
    #expect(decoded.filesGeneratedPatterns == DashboardReviewsPreferences.defaultGeneratedPatterns)
  }

  @Test("legacy preferences default activity inline comments to hidden")
  func activityInlineCommentsLegacyDecodeToHidden() {
    let prefs = DashboardReviewsPreferences.decode(from: "{}")
    #expect(!prefs.showActivityInlineComments)
  }

  @Test("legacy preferences without a preferred group mode default to repository")
  func preferredGroupModeLegacyDecodesToRepository() {
    let prefs = DashboardReviewsPreferences.decode(from: "{}")
    #expect(prefs.preferredGroupModeRaw == DashboardReviewsGroupMode.repository.rawValue)
  }

  @Test("route restores and persists the preferred group mode")
  func routeRestoresAndPersistsPreferredGroupMode() throws {
    let routeSource = try dashboardReviewsRouteSource(named: "DashboardReviewsRouteView.swift")
    let syncSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewsRouteView+StateSync.swift")

    #expect(routeSource.contains(".onChange(of: groupModeRaw)"))
    #expect(routeSource.contains("nextPreferences.preferredGroupModeRaw = newValue"))
    #expect(routeSource.contains("storedPreferences = nextPreferences.encodedString"))
    #expect(syncSource.contains("groupModeRaw = nextPreferences.preferences.preferredGroupModeRaw"))
  }

  @Test("conversation visibility defaults to showing all threads")
  func conversationVisibilityDefaultsToAll() {
    #expect(DashboardReviewsPreferences().filesConversationVisibility == .all)
  }

  @Test("conversation visibility round-trips through Codable storage")
  func conversationVisibilityRoundTrips() {
    var prefs = DashboardReviewsPreferences()
    prefs.filesConversationVisibilityRaw = ConversationVisibility.unresolved.rawValue
    let decoded = DashboardReviewsPreferences.decode(from: prefs.encodedString)
    #expect(decoded.filesConversationVisibility == .unresolved)
  }

  @Test("legacy preferences without the visibility key default to all")
  func conversationVisibilityLegacyDecodesToAll() {
    let prefs = DashboardReviewsPreferences.decode(from: "{}")
    #expect(prefs.filesConversationVisibility == .all)
  }

  @Test("conversation visibility filters threads by resolved state")
  func conversationVisibilityShowsByResolvedState() {
    #expect(!ConversationVisibility.hidden.shows(isResolved: false))
    #expect(!ConversationVisibility.hidden.shows(isResolved: true))
    #expect(ConversationVisibility.unresolved.shows(isResolved: false))
    #expect(!ConversationVisibility.unresolved.shows(isResolved: true))
    #expect(ConversationVisibility.all.shows(isResolved: false))
    #expect(ConversationVisibility.all.shows(isResolved: true))
  }

  @Test("conversation visibility cycles hidden -> unresolved -> all -> hidden")
  func conversationVisibilityCycles() {
    #expect(ConversationVisibility.hidden.cycledNext == .unresolved)
    #expect(ConversationVisibility.unresolved.cycledNext == .all)
    #expect(ConversationVisibility.all.cycledNext == .hidden)
  }

  @Test("conversation visibility uses valid toolbar symbols")
  func conversationVisibilityUsesValidToolbarSymbols() {
    #expect(ConversationVisibility.hidden.systemImage == "eye.slash")
    #expect(ConversationVisibility.unresolved.systemImage == "exclamationmark.bubble")
    #expect(ConversationVisibility.all.systemImage == "bubble.left.and.bubble.right")
  }

  @Test("files tab width round-trips through Codable storage")
  func filesTabWidthRoundTrips() {
    var prefs = DashboardReviewsPreferences()
    prefs.filesTabWidth = 4
    let decoded = DashboardReviewsPreferences.decode(from: prefs.encodedString)
    #expect(decoded.filesTabWidth == 4)
  }

  @Test("legacy preferences without the tab width key default to 8")
  func filesTabWidthLegacyDecodesToDefault() {
    let prefs = DashboardReviewsPreferences.decode(from: "{}")
    #expect(prefs.filesTabWidth == 8)
  }

  @Test("normalized clamps tab width into the supported range")
  func normalizedClampsTabWidth() {
    var prefs = DashboardReviewsPreferences()
    prefs.filesTabWidth = 0
    #expect(
      prefs.normalized().filesTabWidth == DashboardReviewsPreferences.minimumFilesTabWidth
    )

    prefs.filesTabWidth = 999
    #expect(
      prefs.normalized().filesTabWidth == DashboardReviewsPreferences.maximumFilesTabWidth
    )
  }

  @Test("SLA threshold round-trips through Codable storage")
  func slaThresholdRoundTrips() {
    var prefs = DashboardReviewsPreferences()
    prefs.slaThresholdHours = 168
    let decoded = DashboardReviewsPreferences.decode(from: prefs.encodedString)
    #expect(decoded.slaThresholdHours == 168)
  }

  @Test("SLA threshold disabled (nil) round-trips through Codable storage")
  func slaThresholdNilRoundTrips() {
    var prefs = DashboardReviewsPreferences()
    prefs.slaThresholdHours = nil
    let decoded = DashboardReviewsPreferences.decode(from: prefs.encodedString)
    #expect(decoded.slaThresholdHours == nil)
  }

  @Test("legacy preferences without SLA key default to 48")
  func slaThresholdLegacyDecodesToDefault() {
    let prefs = DashboardReviewsPreferences.decode(from: "{}")
    #expect(prefs.slaThresholdHours == 48)
  }
}
