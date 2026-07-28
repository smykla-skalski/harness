import SwiftUI

struct DropDiagnosticsModifier: ViewModifier {
    let mode: BoardMode
    let laneID: String
    let target: String
    let observesSessions: Bool
    let configuresMove: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if observesSessions, configuresMove {
            content
                .onDropSessionUpdated(traceSession)
                .dropConfiguration(configuration)
        } else if observesSessions {
            content.onDropSessionUpdated(traceSession)
        } else if configuresMove {
            content.dropConfiguration(configuration)
        } else {
            content
        }
    }

    private func traceSession(_ session: DropSession) {
        LabTrace.dropSession(
            session,
            mode: mode,
            laneID: laneID,
            target: target,
            event: "drop.session"
        )
    }

    private func configuration(_ session: DropSession) -> DropConfiguration {
        LabTrace.dropSession(
            session,
            mode: mode,
            laneID: laneID,
            target: target,
            event: "drop.configuration"
        )
        var configuration = DropConfiguration(operation: .move)
        configuration.acceptedItemCount = nil
        LabTrace.emit(
            "drop.configuration.result",
            fields: [
                "acceptedItemCount": "<unlimited>",
                "lane": laneID,
                "mode": mode.rawValue,
                "operation": "move",
                "target": target,
            ]
        )
        return configuration
    }
}

extension View {
    func tracedDropTarget(
        mode: BoardMode,
        laneID: String,
        target: String,
        observesSessions: Bool = true,
        configuresMove: Bool = true
    ) -> some View {
        modifier(
            DropDiagnosticsModifier(
                mode: mode,
                laneID: laneID,
                target: target,
                observesSessions: observesSessions,
                configuresMove: configuresMove
            )
        )
    }
}
