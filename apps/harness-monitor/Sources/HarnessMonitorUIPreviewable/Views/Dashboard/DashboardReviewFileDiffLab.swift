import HarnessMonitorKit
import SwiftUI

/// Standalone lab for iterating on the Reviews Files diff renderer in
/// isolation, hosted by the HarnessMonitorPreviewHost executable (the
/// `HarnessMonitorUIPreviews` scheme). Feed it the adversarial fixtures and
/// resize the window to sweep widths so soft wrapping can be eyeballed
/// without launching the full app or a daemon.
public struct DashboardReviewFileDiffLab: View {
  public init() {}

  @State private var fixtureIndex = 0
  @State private var viewMode: FilesViewMode = .split
  @State private var softWrapEnabled = true
  @State private var fontScale: CGFloat = 1
  @State private var tabWidth = 8

  private let fixtures = DashboardReviewFileDiffLabFixture.all

  public var body: some View {
    VStack(spacing: 0) {
      controls
        .padding(12)
      Divider()
      diff
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(red: 0.153, green: 0.157, blue: 0.133))
    }
    .frame(minWidth: 520, minHeight: 380)
  }

  private var fixture: DashboardReviewFileDiffLabFixture {
    fixtures[min(max(fixtureIndex, 0), fixtures.count - 1)]
  }

  private var document: DashboardReviewFileDiffDocument {
    DashboardReviewFileDiffDocument(
      patch: fixture.patch,
      language: fixture.language,
      tabWidth: tabWidth
    )
  }

  @ViewBuilder private var diff: some View {
    switch viewMode {
    case .split:
      DashboardReviewFileDiffSplit(
        patch: fixture.patch,
        language: fixture.language,
        fontScale: fontScale,
        softWrapEnabled: softWrapEnabled,
        minColumnPoints: 220,
        threads: [],
        repositoryFullName: nil,
        fillsAvailableSpace: true,
        document: document
      )
    case .unified:
      DashboardReviewFileDiffUnified(
        patch: fixture.patch,
        language: fixture.language,
        fontScale: fontScale,
        softWrapEnabled: softWrapEnabled,
        threads: [],
        repositoryFullName: nil,
        fillsAvailableSpace: true,
        document: document
      )
    }
  }

  private var controls: some View {
    HStack(spacing: 16) {
      Picker("Fixture", selection: $fixtureIndex) {
        ForEach(Array(fixtures.enumerated()), id: \.offset) { index, fixture in
          Text(fixture.title).tag(index)
        }
      }
      .frame(maxWidth: 230)

      Picker("Mode", selection: $viewMode) {
        Text("Unified").tag(FilesViewMode.unified)
        Text("Split").tag(FilesViewMode.split)
      }
      .pickerStyle(.segmented)
      .fixedSize()

      Toggle("Wrap", isOn: $softWrapEnabled)

      Stepper("Tab \(tabWidth)", value: $tabWidth, in: 1...12)
        .fixedSize()

      HStack(spacing: 6) {
        Text("A").font(.caption)
        Slider(value: $fontScale, in: 0.8...1.8)
          .frame(width: 110)
        Text("A").font(.title3)
      }
      Spacer(minLength: 0)
    }
  }
}
