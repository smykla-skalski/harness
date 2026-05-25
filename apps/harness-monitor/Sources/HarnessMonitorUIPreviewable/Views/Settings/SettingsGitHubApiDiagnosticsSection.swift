import HarnessMonitorKit
import SwiftUI

struct SettingsGitHubApiDiagnosticsSection: View {
  let diagnostics: GitHubApiDiagnostics

  var body: some View {
    Section {
      LabeledContent("Network", value: "\(diagnostics.lastHourNetworkRequests) requests")
      LabeledContent("GraphQL", value: "\(diagnostics.lastHourGraphqlPoints) points")
      LabeledContent("Cache") {
        VStack(alignment: .trailing, spacing: 2) {
          Text("\(diagnostics.cacheHits) hits")
          Text("\(diagnostics.cacheStaleHits) stale, \(diagnostics.cacheDeferredHits) deferred")
            .scaledFont(.caption)
            .foregroundStyle(.secondary)
        }
      }
      if !diagnostics.buckets.isEmpty {
        ForEach(diagnostics.buckets, id: \.resource) { bucket in
          LabeledContent(resourceDisplayName(bucket.resource)) {
            VStack(alignment: .trailing, spacing: 2) {
              Text("\(bucket.remaining) / \(bucket.limit)")
              Text("resets \(bucket.resetAt)")
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
          }
        }
      }
      if !diagnostics.cooling.isEmpty {
        LabeledContent("Cooling") {
          VStack(alignment: .trailing, spacing: 2) {
            ForEach(diagnostics.cooling, id: \.resource) { cooldown in
              Text(
                "\(resourceDisplayName(cooldown.resource)) \(cooldown.untilSecondsFromNow)s"
              )
              .lineLimit(1)
            }
          }
        }
      }
      if !diagnostics.topOperations.isEmpty {
        LabeledContent("Top Spend") {
          VStack(alignment: .trailing, spacing: 2) {
            ForEach(diagnostics.topOperations, id: \.operation) { operation in
              Text(operationSpendText(operation))
                .scaledFont(.caption)
                .lineLimit(1)
            }
          }
        }
      }
    } header: {
      Text("GitHub API")
        .harnessNativeFormSectionHeader()
    }
  }

  private func operationSpendText(_ operation: GitHubOperationSpendDiagnostics) -> String {
    "\(operation.operation): \(operation.graphqlPoints) pts, \(operation.networkRequests) req"
  }

  private func resourceDisplayName(_ resource: String) -> String {
    resource
      .split(separator: "_")
      .map { part in
        part.prefix(1).uppercased() + part.dropFirst()
      }
      .joined(separator: " ")
  }
}
