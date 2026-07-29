import SwiftUI

struct FullParityHost<Content: View>: View {
    private let invalidationInterval: Duration?
    private let content: Content
    @State private var columnVisibility = NavigationSplitViewVisibility.detailOnly
    @State private var inspectorPresented = false
    @State private var invalidationLoadEnabled = true
    @State private var invalidationEpoch = 0

    init(
        invalidationInterval: Duration? = .milliseconds(1_500),
        @ViewBuilder content: () -> Content
    ) {
        self.invalidationInterval = invalidationInterval
        self.content = content()
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            FullParitySidebar()
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 360)
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.prominentDetail)
        .environment(\.fullParityHostInvalidationEpoch, invalidationEpoch)
        .fullParityAncestorTransferReceivers()
        .task(id: invalidationLoadEnabled) {
            guard invalidationLoadEnabled, let invalidationInterval else {
                return
            }
            await runInvalidationLoop(interval: invalidationInterval)
        }
        .onAppear {
            LabTrace.emit(
                "full-parity.host.appear",
                fields: [
                    "invalidationEnabled": String(invalidationInterval != nil),
                    "inspectorPresented": String(inspectorPresented),
                ]
            )
        }
    }

    private var detail: some View {
        verticalViewport
            .navigationTitle("Task Board")
            .navigationSubtitle("Full production host parity")
            .geometryGroup()
            .toolbar {
                FullParityHostToolbar(
                    columnVisibility: $columnVisibility,
                    inspectorPresented: $inspectorPresented,
                    invalidationLoadEnabled: $invalidationLoadEnabled,
                    invalidationAvailable: invalidationInterval != nil
                )
            }
            .inspector(isPresented: $inspectorPresented) {
                FullParityInspector(invalidationEpoch: invalidationEpoch)
                    .inspectorColumnWidth(min: 200, ideal: 240, max: 320)
            }
    }

    private var verticalViewport: some View {
        ScrollView(.vertical) {
            FullParityRetainedRouteLayout(selectedRoute: .taskBoard) {
                content
                    .layoutValue(
                        key: FullParityRetainedRouteKey.self,
                        value: .taskBoard
                    )

                FullParityDormantRoute()
                    .layoutValue(
                        key: FullParityRetainedRouteKey.self,
                        value: .diagnostics
                    )
                    .opacity(0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .containerRelativeFrame(.vertical, alignment: .top)
            .padding(.vertical, 24)
        }
        .scrollBounceBehavior(.basedOnSize)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Dashboard")
    }

    @MainActor
    private func runInvalidationLoop(interval: Duration) async {
        let clock = ContinuousClock()
        while !Task.isCancelled {
            do {
                try await clock.sleep(for: interval)
            } catch {
                return
            }
            guard !Task.isCancelled else {
                return
            }
            invalidationEpoch &+= 1
            LabTrace.emit(
                "full-parity.host.invalidate",
                fields: ["epoch": String(invalidationEpoch)]
            )
        }
    }
}

private struct FullParitySidebar: View {
    var body: some View {
        List {
            Section("Harness") {
                Label("Task Board", systemImage: "rectangle.3.group")
                Label("Sessions", systemImage: "person.2")
                Label("Diagnostics", systemImage: "waveform.path.ecg")
            }
        }
        .listStyle(.sidebar)
        .accessibilityLabel("Dashboard sidebar")
    }
}

private struct FullParityHostToolbar: ToolbarContent {
    @Binding var columnVisibility: NavigationSplitViewVisibility
    @Binding var inspectorPresented: Bool
    @Binding var invalidationLoadEnabled: Bool
    let invalidationAvailable: Bool

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Toggle Sidebar", systemImage: "sidebar.left") {
                columnVisibility =
                    columnVisibility == .detailOnly ? .doubleColumn : .detailOnly
            }
            .help("Show or hide the dashboard sidebar")

            Button("Toggle Inspector", systemImage: "sidebar.right") {
                inspectorPresented.toggle()
            }
            .help("Show or hide the task-board inspector")

            Button(
                invalidationLoadEnabled
                    ? "Pause Host Invalidations"
                    : "Resume Host Invalidations",
                systemImage: invalidationLoadEnabled ? "pause" : "play"
            ) {
                invalidationLoadEnabled.toggle()
                LabTrace.emit(
                    "full-parity.host.invalidation-toggle",
                    fields: ["enabled": String(invalidationLoadEnabled)]
                )
            }
            .disabled(!invalidationAvailable)
            .help("Toggle the production-like ancestor invalidation cadence")
        }
    }
}

private struct FullParityInspector: View {
    let invalidationEpoch: Int

    var body: some View {
        Form {
            Section("Operations") {
                LabeledContent("Queued", value: "0")
                LabeledContent("Host epoch", value: String(invalidationEpoch))
            }
        }
        .formStyle(.grouped)
        .accessibilityLabel("Task-board operations inspector")
    }
}

private struct FullParityDormantRoute: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Diagnostics", systemImage: "waveform.path.ecg")
                .font(.headline)
            Text("Retained route placeholder")
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

private enum FullParityRoute: Hashable {
    case taskBoard
    case diagnostics
}

private struct FullParityRetainedRouteLayout: Layout {
    let selectedRoute: FullParityRoute

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache _: inout ()
    ) -> CGSize {
        selectedSubview(in: subviews)?.sizeThatFits(proposal) ?? .zero
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal _: ProposedViewSize,
        subviews: Subviews,
        cache _: inout ()
    ) {
        selectedSubview(in: subviews)?.place(
            at: bounds.origin,
            proposal: ProposedViewSize(
                width: bounds.width,
                height: bounds.height
            )
        )
    }

    private func selectedSubview(in subviews: Subviews) -> LayoutSubview? {
        subviews.first {
            $0[FullParityRetainedRouteKey.self] == selectedRoute
        } ?? subviews.first
    }
}

private struct FullParityRetainedRouteKey: LayoutValueKey {
    static let defaultValue: FullParityRoute? = nil
}

extension EnvironmentValues {
    @Entry var fullParityHostInvalidationEpoch = 0
}
