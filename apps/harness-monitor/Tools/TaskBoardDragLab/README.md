# Task Board Drag Lab

This standalone macOS 26 SwiftUI executable isolates task-board drag and drop from Harness Monitor. It uses only native SwiftUI drag-and-drop APIs: no AppKit interop, legacy `onDrop` or `DropDelegate`, `GeometryReader`, or custom card-frame tracking. A local dynamic Swift package owns the stage 18 and 19 transfer values so their module and runtime-linkage boundary matches the production transfer package.

## Build and run

From the repository root:

```sh
mise run monitor:task-board-drag-lab
```

`RunLab.swift` packages the SwiftPM executable and transfer library as a local `.app` with a stable bundle identifier, embeds an executable-relative framework search path, exports the production card UTI, ad-hoc signs the complete bundle, then launches it and waits until it exits. This makes the lab addressable by macOS UI automation without adding AppKit to the lab itself.

Do not run the full Harness Monitor app or UI test suite for this lab. Events are emitted through unified logging:

```sh
/usr/bin/log stream --style compact --predicate 'subsystem == "io.harnessmonitor.task-board-drag-lab"'
```

## Scenarios

Use the segmented pickers without resetting the board to compare identical state:

- **List** renders each lane with `List`, and SwiftUI supplies the native insertion offset. Its second picker controls a parity axis:
  - **Direct child** puts `ForEach(...).dropDestination(for:action:)` immediately inside `List`.
  - **Conditional helper** routes the same dynamic rows and modifier through an `@ViewBuilder` conditional returning `some View`, matching the production shape suspected of erasing `DynamicViewContent` semantics.
- **LazyVStack** renders each lane with `ScrollView` and `LazyVStack`. Each row uses the macOS 26 `dropDestination(for:isEnabled:action:)` session overload; `DropSession.location` and `DropSession.size` select the upper or lower half. A visible modern destination below the last card tests the lane-end case directly.

Both modes use direct, closure-based `draggable` payloads, a Codable `Transferable`, `DragConfiguration(allowMove: true)`, `onDragSessionUpdated`, `onDropSessionUpdated`, and `DropConfiguration(operation: .move)`.

The **Drag source** picker isolates payload creation:

- **Transferable** uses the standard `draggable(payload)` modifier and is the known-good baseline.
- **Typed provider** uses `draggable(Payload.self) { payload }`.
- **Drag container** matches Harness Monitor: rows use `draggable(containerItemID:)` and the board uses `dragContainer(for:itemID:)`.

For the focused identity-domain A/B, select **List** and **Drag container**, verify stage **14 · No outer drop wrapper**, then repeat the identical drag at stage **15 · Enum drag identity**. Stage 15 preserves every stage-14 condition, keeps each `ForEach` row keyed by its `String` model ID, and changes only the drag container, `containerItemID`, selection, payload ID, and session lookup to the associated-value `LabCardDragID` enum used by production.

Stage **16 · Production payload shape** preserves the passing stage-15 topology and enum identity domain. It changes only the transferable payload to production's static shape: a non-`Hashable` `Codable`, `Transferable`, `Identifiable`, `Sendable` value containing an array of `Codable`, `Equatable`, `Identifiable`, `Sendable` enum drag items, with `CodableRepresentation` over the same lab content type.

Stage **17 · Initial-only drag lifecycle** preserves stage 16 and changes only drag-session handling: it reads enum IDs, selects cards, and computes candidate lanes during `.initial`; ignores `.active`; and clears drag state during `.ended` and `.dataTransferCompleted`.

Stage **18 · Full production parity** replaces the incremental scaffold with the frozen set of remaining material production conditions:

- the exact `io.harnessmonitor.task-board-card` representation, exported by the app and implemented in the separate dynamic transfer module;
- eleven lanes in production order, including collapsed, empty, umbrella, populated, decision-row, and inbox-row branches;
- production-like `List` topology with heterogeneous siblings and the indexed `DynamicViewContent.dropDestination` owned by the lane's parent;
- `dragContainer`, enum item IDs, reference-observable selection, all-lane acceptance checks, and repeated candidate-payload derivation during the initial drag phase;
- rich card rows, project-color glyphs, context menus, accessibility actions, lane chrome, custom lane strip layout, and partially visible horizontal content;
- `NavigationSplitView`, retained route layout, outer vertical `ScrollView`, `geometryGroup`, toolbar, inspector, image and text ancestor paste destinations, and controlled ancestor invalidation load;
- immediate local order mutation followed by a delayed simulated reconciliation event, allowing the visual settle and later background work to be distinguished in the trace.

Stage **19 · Built-in JSON transfer** is intentionally identical to stage 18 except that its payload uses `CodableRepresentation(contentType: .json)`. If stage 18 cannot activate an indexed destination but stage 19 can, the remaining variable is the custom content type rather than the board topology, state load, or destination-lane structure.

The SDK 27 `reorderable` and `reorderContainer` APIs are intentionally excluded because Harness Monitor currently builds with SDK 26.5.

## Trace sequence

A successful local move should produce these stages:

1. `source.payload`: SwiftUI asked the card for its drag value.
2. `payload.encode`: the transferable representation was requested.
3. `drag.session`: drag session ID, phase, item index, dragged IDs, and location.
4. `drop.session`: destination session ID, phase, item count, local dragged IDs, suggested operations, location, and size.
5. `drop.configuration` and `drop.configuration.result`: the destination evaluated and selected the move operation.
6. `payload.decode`: SwiftUI delivered the Codable payload to the destination.
7. `list.direct.insertion`, `list.helper.insertion`, `lazy.insertion`, `lazy.end.insertion`, or `empty.insertion`: the native destination action ran.
8. `store.mutation`: before/after board order and proposed/resolved offsets.
9. `render.order`: the root-owned observable state was rendered.

Stages 18 and 19 use the equivalent `full-parity.drag.*`, `payload.encode`, `payload.decode`, `full-parity.indexed-destination`, `full-parity.drop`, `store.mutation`, `render.order`, and delayed reconciliation events. The representation field distinguishes the custom-UTI run from the built-in-JSON control without changing any other board condition.

The first missing stage localizes the failure. For example, `source.payload` without `payload.encode` means the source was recognized but its data was never requested; drag session events without drop session events mean no destination became active.

## Suggested checks

For each renderer:

1. Reorder a card within one lane.
2. Move a card between two existing cards in another lane.
3. Move a card to the first position in another lane.
4. Move a card below the last card.
5. Horizontally scroll until a lane is partly clipped, then repeat the cross-lane move.
6. Empty a lane, then drop a card into its empty-state destination.

In List mode, repeat the same drop once with **Direct child** and once with **Conditional helper**. A callback only in the direct route isolates the failure to view-builder/type erasure rather than payload transfer, lane clipping, or state mutation.

Use **Reset** or Command-R to restore deterministic lane contents.
