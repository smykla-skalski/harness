import Foundation
import HarnessMonitorKit

/// Adversarial diff fixtures for the standalone diff lab. Each one targets a
/// soft-wrap edge case: gofmt tab alignment, space alignment, unbreakable
/// tokens, wide CJK, emoji, deep indentation, trailing whitespace, and prose
/// strings. Tabs are real `\t` so the lab exercises tab expansion end to end.
struct DashboardReviewFileDiffLabFixture: Identifiable {
  let id = UUID()
  let title: String
  let patch: ReviewFilePatch
  let language: HarnessReviewFileLanguage

  private static let unbreakableURL =
    "https://example.com/api/v1/resources/"
    + "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    + "?token=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  private static let unbreakableData =
    "data:application/octet-stream;base64,"
    + "QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVowMTIzNDU2Nzg5YWJjZGVmZ2hpamtsbW5vcA=="
  private static let wideCJKNote =
    "这是一段相当长的中文注释用来验证软换行是否按照显示列宽度"
    + "正确折行而不是简单地按照字符数量来折行导致溢出"
  private static let deepIndentExpression =
    "computeSomethingWithAFairlyLongExpression(alpha, beta, gamma, delta)"
  private static let longHelpText =
    "Total number of xDS stream requests rejected because another registration"
    + " for the same proxy is already in progress"

  static let all: [Self] = [
    fixture(
      "Go struct (tabs)",
      language: .go,
      """
      @@ -8,2 +8,5 @@ type Metrics struct {
       \tXdsGenerations\t*prometheus.HistogramVec
      -\tXdsGenerationsErrors\tprometheus.Counter
      +\tXdsGenerationsErrors\tprometheus.Counter
      +\tKubeAuthCache\t*prometheus.CounterVec
      +\tCertExpirationTimestamp\t*prometheus.GaugeVec
      +\tXdsStreamRegistrationInProgressRetries\t*prometheus.CounterVec
      """
    ),
    fixture(
      "Go struct (spaces)",
      language: .go,
      """
      @@ -8,2 +8,5 @@ type Metrics struct {
           XdsGenerations                         *prometheus.HistogramVec
      -    XdsGenerationsErrors                   prometheus.Counter
      +    XdsGenerationsErrors                   prometheus.Counter
      +    KubeAuthCache                          *prometheus.CounterVec
      +    CertExpirationTimestamp                *prometheus.GaugeVec
      +    XdsStreamRegistrationInProgressRetries *prometheus.CounterVec
      """
    ),
    fixture(
      "Unbreakable token",
      language: .javascript,
      """
      @@ -1,1 +1,3 @@
       const base = "start"
      +const url = "\(Self.unbreakableURL)"
      +const data = "\(Self.unbreakableData)"
      """
    ),
    fixture(
      "Wide CJK",
      language: .go,
      """
      @@ -1,1 +1,2 @@
       greeting := "hello"
      +note := "\(Self.wideCJKNote)"
      """
    ),
    fixture(
      "Emoji run",
      language: .javascript,
      """
      @@ -1,1 +1,2 @@
       const a = 1
      +const status = "✅ done 🚀 shipping 🎉 celebrate 🔥 hot 💯 perfect 🌈 colors 🦄 unicorn 🍕 lunch 🛰️ orbit"
      """
    ),
    fixture(
      "Deep indentation",
      language: .swift,
      """
      @@ -1,1 +1,3 @@
       func outer() {
      +                if deeplyNested && anotherCondition && yetAnotherOne && finalGuard {
      +                                return \(Self.deepIndentExpression)
      """
    ),
    fixture(
      "Trailing + empty + tab",
      language: .go,
      """
      @@ -1,1 +1,4 @@
       lineOne := true
      +lineWithTrailingSpaces := true            \n+
      +\ttabbedAfterBlank := false
      """
    ),
    fixture(
      "Help prose string",
      language: .go,
      """
      @@ -39,2 +39,3 @@ func NewMetrics() {
       \t\tName: "xds_stream_registration_in_progress_retries_total",
      +\t\tHelp: "\(Self.longHelpText)",
      +\t}, []string{"mesh", "proxy_type"})
      """
    ),
  ]

  private static func fixture(
    _ title: String,
    language: HarnessReviewFileLanguage,
    _ patch: String
  ) -> Self {
    Self(
      title: title,
      patch: ReviewFilePatch(
        path: "Sources/Fixture.\(language == .go ? "go" : "txt")",
        patch: patch,
        status: .modified,
        additions: 4,
        deletions: 1,
        fetchedAt: "2026-05-25T12:00:00Z",
        headRefOid: "labfixture"
      ),
      language: language
    )
  }
}
