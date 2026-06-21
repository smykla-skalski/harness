import AppKit
import HarnessMonitorKit
import SwiftUI

struct DashboardAuditDetailPane: View {
  let event: HarnessMonitorAuditEvent?
  let notificationEntry: NotificationHistoryEntry?
  let store: HarnessMonitorStore
  let configuration: HarnessMonitorDateTimeConfiguration

  var body: some View {
    Group {
      if let event {
        ScrollView {
          VStack(alignment: .leading, spacing: 18) {
            header(event)
            InspectorFactGrid(facts: facts(for: event))
            payloadSection(event)
            legacySection(event)
            notificationActions
            relatedLinks(event)
          }
          .padding(20)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      } else {
        ContentUnavailableView {
          Label("Select an audit event", systemImage: "sidebar.right")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
  }

  private func header(_ event: HarnessMonitorAuditEvent) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: event.auditSourceIcon)
        .font(.title2)
        .foregroundStyle(event.auditTint)
        .frame(width: 34, height: 34)
      VStack(alignment: .leading, spacing: 6) {
        Text(event.title)
          .scaledFont(.system(.title3, design: .rounded, weight: .semibold))
        Text(event.summary)
          .scaledFont(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
      Button {
        copyEvent(event)
      } label: {
        Image(systemName: "doc.on.doc")
      }
      .help("Copy audit event")
    }
  }

  private func facts(for event: HarnessMonitorAuditEvent) -> [InspectorFact] {
    var facts = [
      InspectorFact(title: "Source", value: event.source.auditDisplayLabel),
      InspectorFact(title: "Category", value: event.category.auditDisplayLabel),
      InspectorFact(title: "Kind", value: event.kind),
      InspectorFact(title: "Severity", value: event.severity.auditDisplayLabel),
      InspectorFact(title: "Outcome", value: event.outcome.auditDisplayLabel),
      InspectorFact(
        title: "Recorded",
        value: formatTimelineTimestamp(event.recordedAt, configuration: configuration)
      ),
    ]
    if let subject = event.subject {
      facts.append(InspectorFact(title: "Subject", value: subject))
    }
    if let actor = event.actor {
      facts.append(InspectorFact(title: "Actor", value: actor))
    }
    if let correlationID = event.correlationID {
      facts.append(InspectorFact(title: "Correlation", value: correlationID))
    }
    if let actionKey = event.actionKey {
      facts.append(InspectorFact(title: "Action", value: actionKey))
    }
    facts.append(InspectorFact(title: "Event ID", value: event.id))
    return facts
  }

  @ViewBuilder
  private func payloadSection(_ event: HarnessMonitorAuditEvent) -> some View {
    if let payload = event.payloadJSONString() {
      DashboardAuditJSONPayloadBlock(title: "Payload", payload: payload)
    }
  }

  @ViewBuilder
  private func legacySection(_ event: HarnessMonitorAuditEvent) -> some View {
    if let legacyMessage = event.legacyMessage {
      DashboardAuditTextBlock(title: "Legacy Message", text: legacyMessage)
    }
  }

  @ViewBuilder private var notificationActions: some View {
    if let notificationEntry, !notificationEntry.actions.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        Text("Actions")
          .scaledFont(.headline)
        HStack(spacing: 8) {
          ForEach(notificationEntry.actions) { action in
            Button {
              Task {
                _ = await store.performNotificationHistoryAction(
                  entryID: notificationEntry.id,
                  action: action
                )
              }
            } label: {
              Label(action.title, systemImage: action.systemImage)
            }
            .accessibilityIdentifier(
              HarnessMonitorAccessibility.dashboardNotificationAction(
                notificationEntry.id,
                actionID: action.id
              )
            )
          }
        }
      }
    }
  }

  @ViewBuilder
  private func relatedLinks(_ event: HarnessMonitorAuditEvent) -> some View {
    if !event.relatedURLs.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        Text("Related")
          .scaledFont(.headline)
        ForEach(event.relatedURLs, id: \.self) { rawURL in
          Button {
            if let url = URL(string: rawURL) {
              NSWorkspace.shared.open(url)
            }
          } label: {
            Label(rawURL, systemImage: "link")
              .lineLimit(1)
          }
          .buttonStyle(.link)
        }
      }
    }
  }

  private func copyEvent(_ event: HarnessMonitorAuditEvent) {
    let text: String
    do {
      text = try event.clipboardJSONString()
    } catch {
      store.presentFailureFeedback("Could not copy audit event: \(error.localizedDescription)")
      return
    }
    NSPasteboard.general.clearContents()
    guard NSPasteboard.general.setString(text, forType: .string) else {
      store.presentFailureFeedback("Could not copy audit event to the clipboard.")
      return
    }
  }
}

private struct DashboardAuditJSONPayloadBlock: View {
  let title: String
  let payload: String

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .scaledFont(.headline)
      HarnessMonitorJSONCodeBlock(rawJSON: payload)
    }
  }
}

private struct DashboardAuditTextBlock: View {
  let title: String
  let text: String

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .scaledFont(.headline)
      ScrollView(.horizontal) {
        Text(text)
          .font(.system(.caption, design: .monospaced))
          .textSelection(.enabled)
          .padding(10)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
    }
  }
}
