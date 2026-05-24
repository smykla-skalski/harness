import Foundation
import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Harness Monitor voice routing")
struct HarnessMonitorStoreVoiceTests {
  @Test("Voice session requests keep routing, locale, and confirmation explicit")
  func voiceSessionRequestsKeepRoutingLocaleAndConfirmationExplicit() async {
    let client = RecordingHarnessClient()
    let store = await selectedStore(client: client)

    let response = await store.startVoiceProcessingSession(
      localeIdentifier: "en_US",
      requestedSinks: [.localDaemon, .agentBridge],
      routeTarget: .codexPrompt,
      remoteProcessorURL: nil,
      requiresConfirmation: true,
      actor: "leader-claude"
    )

    #expect(response?.voiceSessionId == "voice-session-1")
    #expect(
      client.recordedCalls()
        == [
          .startVoiceSession(
            sessionID: PreviewFixtures.summary.sessionId,
            localeIdentifier: "en_US",
            sinks: [.localDaemon, .agentBridge],
            routeTarget: .codexPrompt,
            requiresConfirmation: true,
            remoteProcessorURL: nil,
            actor: "leader-claude"
          )
        ]
    )
  }

  @Test("Voice session requests keep remote processor endpoints explicit")
  func voiceSessionRequestsKeepRemoteProcessorEndpointsExplicit() async {
    let client = RecordingHarnessClient()
    let store = await selectedStore(client: client)

    let response = await store.startVoiceProcessingSession(
      localeIdentifier: "pl_PL",
      requestedSinks: [.remoteProcessor, .agentBridge],
      routeTarget: .codexContext(runID: "run-123"),
      remoteProcessorURL: URL(string: "https://processor.example/voice"),
      requiresConfirmation: false,
      actor: "leader-claude"
    )

    #expect(response?.voiceSessionId == "voice-session-1")
    #expect(
      client.recordedCalls()
        == [
          .startVoiceSession(
            sessionID: PreviewFixtures.summary.sessionId,
            localeIdentifier: "pl_PL",
            sinks: [.remoteProcessor, .agentBridge],
            routeTarget: .codexContext(runID: "run-123"),
            requiresConfirmation: false,
            remoteProcessorURL: "https://processor.example/voice",
            actor: "leader-claude"
          )
        ]
    )
  }

  @Test("Voice chunks and transcript updates route through the daemon voice session")
  func voiceChunksAndTranscriptUpdatesRouteThroughDaemonVoiceSession() async {
    let client = RecordingHarnessClient()
    let store = await selectedStore(client: client)
    let chunk = VoiceAudioChunk(
      sequence: 1,
      format: VoiceAudioFormatDescriptor(
        sampleRate: 48_000,
        channelCount: 1,
        commonFormat: "pcm_f32",
        interleaved: false
      ),
      frameCount: 4,
      startedAtSeconds: 0,
      durationSeconds: 0.01,
      audioData: Data([1, 2, 3, 4])
    )
    let segment = VoiceTranscriptSegment(
      sequence: 1,
      text: "patch the failing test",
      isFinal: true,
      startedAtSeconds: 0,
      durationSeconds: 0.5
    )

    await store.appendVoiceAudioChunk(voiceSessionID: "voice-session-1", chunk: chunk)
    await store.appendVoiceTranscript(voiceSessionID: "voice-session-1", segment: segment)
    await store.finishVoiceProcessingSession(
      voiceSessionID: "voice-session-1",
      reason: .completed,
      confirmedText: "patch the failing test"
    )

    #expect(
      client.recordedCalls()
        == [
          .appendVoiceAudioChunk(
            voiceSessionID: "voice-session-1",
            sequence: 1,
            actor: "leader-claude"
          ),
          .appendVoiceTranscript(
            voiceSessionID: "voice-session-1",
            sequence: 1,
            actor: "leader-claude"
          ),
          .finishVoiceSession(
            voiceSessionID: "voice-session-1",
            reason: .completed,
            confirmedText: "patch the failing test",
            actor: "leader-claude"
          ),
        ]
    )
  }

  private func selectedStore(client: RecordingHarnessClient) async -> HarnessMonitorStore {
    let store = await makeBootstrappedStore(client: client)
    await store.selectSession(PreviewFixtures.summary.sessionId)
    return store
  }
}

@MainActor
@Suite("System voice text insertion")
struct SystemVoiceTextInsertionServiceTests {
  @Test("Insert keeps text in-app when Accessibility permission is missing")
  func insertConfirmedTextKeepsTextInAppWhenAccessibilityPermissionIsMissing() {
    let pasteboard = PasteboardSpy()
    let insertion = AccessibilityInsertionSpy()
    let service = SystemVoiceTextInsertionService(
      accessibilityTrustCheck: { _ in false },
      accessibilityInserter: { text in
        insertion.record(text)
        return false
      },
      pasteboardWriter: { text in
        pasteboard.record(text)
      }
    )

    let result = service.insertConfirmedText(" dictated text ", promptForAccessibility: false)

    #expect(result == .accessibilityPermissionRequired)
    #expect(insertion.insertedTexts.isEmpty)
    #expect(pasteboard.copiedTexts.isEmpty)
  }

  @Test("Insert keeps text in-app when direct insertion fails")
  func insertConfirmedTextKeepsTextInAppWhenDirectInsertionFails() {
    let pasteboard = PasteboardSpy()
    let insertion = AccessibilityInsertionSpy()
    let service = SystemVoiceTextInsertionService(
      accessibilityTrustCheck: { _ in true },
      accessibilityInserter: { text in
        insertion.record(text)
        return false
      },
      pasteboardWriter: { text in
        pasteboard.record(text)
      }
    )

    let result = service.insertConfirmedText(" dictated text ")

    #expect(result == .manualInsertionRequired)
    #expect(insertion.insertedTexts == ["dictated text"])
    #expect(pasteboard.copiedTexts.isEmpty)
  }

  @Test("Copy to pasteboard requires explicit user action")
  func copyTextToPasteboardRequiresExplicitUserAction() {
    let pasteboard = PasteboardSpy()
    let service = SystemVoiceTextInsertionService(
      accessibilityTrustCheck: { _ in true },
      accessibilityInserter: { _ in true },
      pasteboardWriter: { text in
        pasteboard.record(text)
      }
    )

    let copied = service.copyTextToPasteboard(" dictated text ")

    #expect(copied)
    #expect(pasteboard.copiedTexts == ["dictated text"])
  }
}

private final class PasteboardSpy: @unchecked Sendable {
  private(set) var copiedTexts: [String] = []

  func record(_ text: String) {
    copiedTexts.append(text)
  }
}

private final class AccessibilityInsertionSpy: @unchecked Sendable {
  private(set) var insertedTexts: [String] = []

  func record(_ text: String) {
    insertedTexts.append(text)
  }
}
