import SwiftUI

struct ContentView: View {
    @State private var mode = BoardMode.list
    @State private var listContentRoute = ListContentRoute.productionSiblings
    @State private var dragSourceMode = DragSourceMode.container
    @State private var parityStage = LabParityStage.fullProductionParity
    @State private var store = BoardStore(parityStage: .fullProductionParity)

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            BoardView(
                mode: mode,
                listContentRoute: listContentRoute,
                dragSourceMode: dragSourceMode,
                parityStage: parityStage,
                store: store
            )
        }
        .frame(minWidth: 900, minHeight: 600)
        .onAppear {
            LabTrace.emit("app.appear", fields: ["mode": mode.rawValue])
            store.traceRenderedOrder(reason: "initial")
        }
        .onChange(of: mode) { oldMode, newMode in
            LabTrace.emit(
                "mode.change",
                fields: ["from": oldMode.rawValue, "to": newMode.rawValue]
            )
            store.traceRenderedOrder(reason: "mode-change")
        }
        .onChange(of: listContentRoute) { oldRoute, newRoute in
            LabTrace.emit(
                "list-route.change",
                fields: ["from": oldRoute.rawValue, "to": newRoute.rawValue]
            )
            store.traceRenderedOrder(reason: "list-route-change")
        }
        .onChange(of: dragSourceMode) { oldMode, newMode in
            LabTrace.emit(
                "source-mode.change",
                fields: ["from": oldMode.rawValue, "to": newMode.rawValue]
            )
            store.traceRenderedOrder(reason: "source-mode-change")
        }
        .onChange(of: parityStage) { oldStage, newStage in
            LabTrace.emit(
                "parity-stage.change",
                fields: ["from": oldStage.title, "to": newStage.title]
            )
            if newStage.usesFullProductionParity {
                mode = newStage.usesFullProductionScrollView ? .lazyVStack : .list
                listContentRoute = .productionSiblings
                dragSourceMode = .container
            }
            store.configure(for: newStage)
        }
        .onChange(of: store.orderSignature) {
            store.traceRenderedOrder(reason: "SwiftUI-observed-store-change")
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Picker("Renderer", selection: $mode) {
                    ForEach(BoardMode.allCases) { candidate in
                        Text(candidate.rawValue).tag(candidate)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
                .disabled(parityStage.usesFullProductionParity)

                Picker("List content", selection: $listContentRoute) {
                    ForEach(ListContentRoute.allCases) { route in
                        Text(route.rawValue).tag(route)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 250)
                .disabled(mode != .list || parityStage.usesProductionSiblings)

                Picker("Drag source", selection: $dragSourceMode) {
                    ForEach(DragSourceMode.allCases) { sourceMode in
                        Text(sourceMode.rawValue).tag(sourceMode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 360)
                .disabled(parityStage.usesFullProductionParity)

                Button("Reset", systemImage: "arrow.counterclockwise") {
                    store.reset()
                }
                .keyboardShortcut("r", modifiers: [.command])

                Spacer()
            }

            HStack(spacing: 12) {
                Picker("Production parity", selection: $parityStage) {
                    ForEach(LabParityStage.allCases) { stage in
                        Text(stage.title).tag(stage)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 330)

                Text(parityStage.dragInstruction)
                    .font(.callout.weight(.semibold))

                Spacer()

                Text("Advance one stage only after the previous drag succeeds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }
}
