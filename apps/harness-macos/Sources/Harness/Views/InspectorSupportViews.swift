import HarnessKit
import SwiftData
import SwiftUI

struct ObserverInspectorCard: View {
  let observer: ObserverSummary

  private var facts: [InspectorFact] {
    [
      .init(title: "Observer", value: observer.observeId),
      .init(title: "Open Issues", value: "\(observer.openIssueCount)"),
      .init(title: "Resolved", value: "\(observer.resolvedIssueCount)"),
      .init(title: "Active Workers", value: "\(observer.activeWorkerCount)"),
      .init(title: "Muted Codes", value: "\(observer.mutedCodeCount)"),
      .init(title: "Last Sweep", value: formatTimestamp(observer.lastScanTime)),
    ]
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessTheme.sectionSpacing) {
      Text("Observe")
        .scaledFont(.system(.title3, design: .rounded, weight: .bold))
        .accessibilityAddTraits(.isHeader)
      InspectorFactGrid(facts: facts)
      if let mutedCodes = observer.mutedCodes, !mutedCodes.isEmpty {
        InspectorSection(title: "Muted Codes") {
          let formatted = mutedCodes.map { $0.replacing("_", with: " ") }
          InspectorBadgeColumn(values: formatted)
        }
      }
      if let openIssues = observer.openIssues, !openIssues.isEmpty {
        ObserverOpenIssuesSection(issues: openIssues)
      }
      if let activeWorkers = observer.activeWorkers, !activeWorkers.isEmpty {
        ObserverWorkersSection(workers: activeWorkers)
      }
      if let cycleHistory = observer.cycleHistory, !cycleHistory.isEmpty {
        DisclosureGroup("Cycle History") {
          ObserverCycleHistoryContent(cycles: cycleHistory)
        }
        .scaledFont(.caption.bold())
        .foregroundStyle(HarnessTheme.secondaryInk)
      }
      if let agentSessions = observer.agentSessions, !agentSessions.isEmpty {
        DisclosureGroup("Tracked Agent Sessions") {
          ObserverAgentSessionsContent(sessions: agentSessions)
        }
        .scaledFont(.caption.bold())
        .foregroundStyle(HarnessTheme.secondaryInk)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityTestProbe(
      HarnessAccessibility.observerInspectorCard,
      label: "Observe",
      value: "\(observer.openIssueCount)"
    )
    .accessibilityFrameMarker("\(HarnessAccessibility.observerInspectorCard).frame")
  }
}

struct InspectorFact: Identifiable {
  let title: String
  let value: String
  var id: String { title }
}

private struct ObserverOpenIssuesSection: View {
  let issues: [ObserverIssueSummary]

  var body: some View {
    InspectorSection(title: "Open Issues") {
      VStack(alignment: .leading, spacing: HarnessTheme.itemSpacing) {
        ForEach(issues) { issue in
          VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
              Text(issue.code)
                .scaledFont(.caption.bold())
                .textCase(.uppercase)
              Spacer()
              Text(issue.severity.capitalized)
                .scaledFont(.caption2.bold())
            }
            Text(issue.summary)
              .scaledFont(.subheadline)
            if let evidenceExcerpt = issue.evidenceExcerpt {
              Text(evidenceExcerpt)
                .scaledFont(.caption)
                .foregroundStyle(HarnessTheme.secondaryInk)
                .lineLimit(2)
            }
          }
          .harnessCellPadding()
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

private struct ObserverWorkersSection: View {
  let workers: [ObserverWorkerSummary]

  var body: some View {
    InspectorSection(title: "Active Workers") {
      VStack(alignment: .leading, spacing: HarnessTheme.itemSpacing) {
        ForEach(workers) { worker in
          VStack(alignment: .leading, spacing: 4) {
            HStack {
              Text(worker.agentId ?? "worker")
                .scaledFont(.subheadline.bold())
              Spacer()
              Text(formatTimestamp(worker.startedAt))
                .scaledFont(.caption.monospaced())
                .foregroundStyle(HarnessTheme.secondaryInk)
            }
            Text(worker.targetFile)
              .scaledFont(.caption)
              .truncationMode(.middle)
              .foregroundStyle(HarnessTheme.secondaryInk)
              .lineLimit(2)
          }
          .harnessCellPadding()
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

private struct ObserverCycleHistoryContent: View {
  let cycles: [ObserverCycleSummary]

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessTheme.itemSpacing) {
      ForEach(cycles) { cycle in
        VStack(alignment: .leading, spacing: 4) {
          HStack {
            Text(formatTimestamp(cycle.timestamp))
              .scaledFont(.caption.monospaced())
            Spacer()
            Text("+\(cycle.newIssues) / -\(cycle.resolved)")
              .scaledFont(.caption.bold())
              .foregroundStyle(HarnessTheme.secondaryInk)
          }
          Text("Lines \(cycle.fromLine) - \(cycle.toLine)")
            .scaledFont(.caption)
            .foregroundStyle(HarnessTheme.secondaryInk)
        }
        .harnessCellPadding()
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct ObserverAgentSessionsContent: View {
  let sessions: [ObserverAgentSessionSummary]

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessTheme.itemSpacing) {
      ForEach(sessions) { session in
        VStack(alignment: .leading, spacing: 4) {
          HStack {
            Text(session.agentId)
              .scaledFont(.subheadline.bold())
            Spacer()
            Text(session.runtime.uppercased())
              .scaledFont(.caption2.bold())
              .tracking(HarnessTheme.uppercaseTracking)
              .foregroundStyle(HarnessTheme.secondaryInk)
          }
          Text("Cursor \(session.cursor)")
            .scaledFont(.caption.monospaced())
          if let lastActivity = session.lastActivity {
            Text("Last activity \(formatTimestamp(lastActivity))")
              .scaledFont(.caption)
              .foregroundStyle(HarnessTheme.secondaryInk)
          }
          if let logPath = session.logPath {
            Text(logPath)
              .scaledFont(.caption.monospaced())
              .truncationMode(.middle)
              .foregroundStyle(HarnessTheme.secondaryInk)
              .lineLimit(2)
          }
        }
        .harnessCellPadding()
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct InspectorFactGrid: View {
  let facts: [InspectorFact]

  var body: some View {
    HarnessAdaptiveGridLayout(minimumColumnWidth: 132, maximumColumns: 2, spacing: HarnessTheme.itemSpacing) {
      ForEach(facts) { fact in
        VStack(alignment: .leading, spacing: 4) {
          Text(fact.title.uppercased())
            .scaledFont(.caption2.weight(.bold))
            .tracking(HarnessTheme.uppercaseTracking)
            .foregroundStyle(HarnessTheme.secondaryInk)
          Text(fact.value)
            .scaledFont(.system(.body, design: .rounded, weight: .semibold))
            .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .harnessCellPadding()
      }
    }
  }
}

struct InspectorSection<Content: View>: View {
  let title: String
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessTheme.itemSpacing) {
      Text(title)
        .scaledFont(.caption.bold())
        .foregroundStyle(HarnessTheme.secondaryInk)
      content
    }
  }
}

struct InspectorBadgeColumn: View {
  let values: [String]

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessTheme.itemSpacing) {
      ForEach(Array(values.enumerated()), id: \.offset) { _, value in
        Text(value)
          .scaledFont(.caption.weight(.semibold))
          .harnessPillPadding()
          .harnessInfoPill()
      }
    }
  }
}

struct InspectorObserverSummarySection: View {
  let observer: ObserverSummary

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessTheme.itemSpacing) {
      HarnessActionHeader(
        title: "Observe",
        subtitle: "The observer loop keeps the session moving and surfaces drift."
      )
      HStack(spacing: HarnessTheme.itemSpacing) {
        HarnessBadge(value: "Open \(observer.openIssueCount)")
        HarnessBadge(value: "Muted \(observer.mutedCodeCount)")
        HarnessBadge(value: "Workers \(observer.activeWorkerCount)")
      }
      Text("Last sweep \(formatTimestamp(observer.lastScanTime))")
        .scaledFont(.caption.monospaced())
        .foregroundStyle(HarnessTheme.secondaryInk)
      if let mutedCodes = observer.mutedCodes, !mutedCodes.isEmpty {
        Text("Muted codes")
          .scaledFont(.caption.bold())
          .foregroundStyle(HarnessTheme.secondaryInk)
        Text(mutedCodes.prefix(3).joined(separator: " · "))
          .scaledFont(.caption)
          .foregroundStyle(HarnessTheme.secondaryInk)
      }
      if let openIssues = observer.openIssues, !openIssues.isEmpty {
        Text("Open issues")
          .scaledFont(.caption.bold())
          .foregroundStyle(HarnessTheme.secondaryInk)
        VStack(alignment: .leading, spacing: HarnessTheme.itemSpacing) {
          ForEach(openIssues.prefix(2)) { issue in
            VStack(alignment: .leading, spacing: 2) {
              Text("\(issue.code) · \(issue.summary)")
                .scaledFont(.caption)
              Text("Severity \(issue.severity.capitalized)")
                .scaledFont(.caption2)
                .foregroundStyle(HarnessTheme.secondaryInk)
            }
          }
        }
      }
      if let activeWorkers = observer.activeWorkers, !activeWorkers.isEmpty {
        Text("Active workers")
          .scaledFont(.caption.bold())
          .foregroundStyle(HarnessTheme.secondaryInk)
        VStack(alignment: .leading, spacing: HarnessTheme.itemSpacing) {
          ForEach(activeWorkers.prefix(2)) { worker in
            VStack(alignment: .leading, spacing: 2) {
              Text(worker.agentId ?? "worker")
                .scaledFont(.caption)
              Text(worker.targetFile)
                .scaledFont(.caption2)
                .foregroundStyle(HarnessTheme.secondaryInk)
                .lineLimit(1)
            }
          }
        }
      }
    }
  }
}

struct TaskUserNotesSection: View {
  let store: HarnessStore
  let taskID: String
  let sessionID: String
  @State private var newNoteText = ""
  @FocusState private var isNoteFieldFocused: Bool

  private var userNotes: [UserNote] {
    store.notes(for: "task", targetId: taskID, sessionId: sessionID)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessTheme.itemSpacing) {
      if !userNotes.isEmpty {
        VStack(alignment: .leading, spacing: HarnessTheme.itemSpacing) {
          ForEach(userNotes, id: \.persistentModelID) { note in
            HStack(alignment: .top) {
              Text(note.text)
                .scaledFont(.subheadline)
                .foregroundStyle(HarnessTheme.secondaryInk)
                .frame(maxWidth: .infinity, alignment: .leading)
              Button {
                store.deleteNote(note)
              } label: {
                Image(systemName: "xmark.circle.fill")
                  .scaledFont(.caption)
                  .foregroundStyle(HarnessTheme.danger)
                  .frame(minWidth: 24, minHeight: 24)
                  .contentShape(Rectangle())
              }
              .accessibilityLabel("Delete Note")
              .accessibilityHint("Removes this note from the selected task.")
              .help("Delete note")
              .harnessDismissButtonStyle()
            }
            .harnessCellPadding()
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }

      HStack(spacing: HarnessTheme.itemSpacing) {
        TextField("Add a note", text: $newNoteText)
          .focused($isNoteFieldFocused)
          .textFieldStyle(.roundedBorder)
          .submitLabel(.done)
          .accessibilityIdentifier(HarnessAccessibility.taskNoteField)
          .onSubmit { submitNote() }
        Button("Add") { submitNote() }
          .harnessActionButtonStyle(variant: .bordered)
          .accessibilityIdentifier(HarnessAccessibility.taskNoteAddButton)
          .disabled(newNoteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
  }

  private func submitNote() {
    let text = newNoteText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    guard store.addNote(
      text: text,
      targetKind: "task",
      targetId: taskID,
      sessionId: sessionID
    ) else {
      return
    }

    newNoteText = ""
    isNoteFieldFocused = false
  }
}

struct PersistenceUnavailableNotesState: View {
  var body: some View {
    Text("Persistent notes are unavailable while the local store is offline.")
      .scaledFont(.subheadline)
      .foregroundStyle(HarnessTheme.secondaryInk)
      .accessibilityIdentifier(HarnessAccessibility.taskNotesUnavailable)
  }
}

extension JSONValue {
  private static let prettyEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return encoder
  }()

  func prettyPrintedJSONString() -> String {
    guard let data = try? Self.prettyEncoder.encode(self),
      let string = String(data: data, encoding: .utf8)
    else {
      return "null"
    }
    return string
  }
}
