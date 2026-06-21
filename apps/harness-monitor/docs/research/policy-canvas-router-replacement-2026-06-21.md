# Policy Canvas edge-router replacement: research report

Date: 2026-06-21. Status: research only, no code change implied. Prepared on request to evaluate replacing the hand-written A* orthogonal-visibility edge router with a proven library or a better algorithm, so the decision can be made later from a full picture.

## What the current router does

Orthogonal (right-angle) wires between node ports, avoiding node-body rectangles as obstacles, built on a padded orthogonal visibility graph plus A* that minimizes bends then length. Around that core sit the app's own passes: port-marker placement, lane assignment for parallel edges, label placement, terminal-order and crossed-port repair, and selective reroute of only the edges incident to a moved node during a live drag (a coalescer keeps one recompute in flight; drag tick and drop share the same path).

## Executive summary and recommendation

1. The custom router is already on the canonical, state-of-the-art algorithm. "Orthogonal visibility graph + A* (bends then length), then order/center/nudge parallel edges in shared channels, with incremental reroute on drag" is exactly the Wybrow/Marriott/Stuckey pipeline that libavoid implements and that Inkscape, Dunnart, ELK (via its libavoid bridge), and others converge on. There is no fundamentally different algorithm class that fits a free-form, user-positioned canvas better.

2. There is no pure-Swift or Apple-framework drop-in. GameplayKit does any-angle navigation (`GKObstacleGraph`) or grid-cardinal A* with stair-stepping and no port or bend control (`GKGridGraph`); MapKit, PencilKit, SpriteKit, Accelerate are unrelated. The Swift graph libraries (SwiftGraph, swift-graphs) and `swift-collections` give you A*/Dijkstra primitives and a priority queue, not a router. So the realistic choices are: keep and refine the in-house router, or bind the one mature C++ engine (libavoid).

3. libavoid (Adaptagrams) is the only proven library that does exactly this job, including a `SelectiveReroute` transaction model that maps one-to-one onto the existing selective-drag work. But adopting it means the same algorithm you already run, plus a C++ dependency, an LGPL-2.1 obligation, a determinism question against the golden-geometry tests, and a non-trivial re-fit of the surrounding port/lane/label passes onto its output.

4. Recommended direction, in priority order, all inside the current implementation rather than a swap:
   - Adopt the 1-bend visibility graph ("Seeing Around Corners", Diagrams 2014) if A* over a dense per-corner visibility graph is the drag-time hotspot. Biggest single algorithmic win available.
   - If lane assignment is heuristic, replace it with metro-line-style ordering (cross only at channel entry/exit) plus separation-constraint nudging (GD 2009).
   - Add local incremental visibility-graph updates on a move, and consider the GD 2005 rule of also reconsidering non-incident connectors that a moved node now blocks or frees.
   - Standardize the A* open set on `swift-collections` `Heap`/`PriorityQueue` (Apache 2.0) if not already.
   - Treat libavoid as a specification and a test oracle, and reach for it as a dependency only if maintaining the algorithm in-house becomes the actual bottleneck and the LGPL question can be cleared.

The bug that triggered this (a wire left crossing a node body after a node is dropped onto an open-lane wire) is the GD 2005 "reconsider connectors the moved node now blocks" case. It is being fixed in-house with a guaranteed go-around in the body-hit repair, independent of any library decision.

## 1. Algorithm assessment

### libavoid is the reference design (and it is the same algorithm)

Three stages, matching the in-house router almost exactly: build an orthogonal visibility graph from obstacle corners and ports; A* per connector minimizing total length plus bend count; post-process by ordering, centering, and nudging connectors that share a channel so parallel wires are evenly spaced and only cross at entry/exit.

- "Orthogonal Connector Routing", Wybrow, Marriott, Stuckey, GD 2009 - the OVG + A* + nudging pipeline. https://users.monash.edu/~mwybrow/papers/wybrow-gd-2009.pdf
- "Incremental Connector Routing", GD 2005 - rerouting during interactive drags; on a move it reroutes the connectors attached to the moved object and reconsiders other connectors whose route the move made better or worse, updating the visibility graph locally rather than rebuilding it. https://ialab.it.monash.edu/~mwybrow/papers/wybrow-gd-2005.pdf
- "Seeing Around Corners: Fast Orthogonal Connector Routing", Diagrams 2014 - the 1-bend visibility graph; larger to build but routing over it is significantly faster. https://users.monash.edu/~mwybrow/papers/marriott-diagrams-2014.pdf

The highest-leverage algorithm change, if profiling points at A* over a dense visibility graph, is the 1-bend graph from the 2014 paper. It is a change you make inside the custom router, not a library swap.

### ELK and KLay

ELK's orthogonal router is layer-based: it routes in the channels between layers produced by a Sugiyama-style hierarchical layout (Sander; Di Battista et al.). That is the wrong model for a free-form canvas where nodes are dragged anywhere and obstacles are arbitrary. Tellingly, ELK's own answer for general obstacle-avoiding routing is to bridge out to libavoid (`org.eclipse.elk.alg.libavoid`). Borrow the slot/channel ordering idea for lanes; do not adopt ELK itself unless the app moves to automatic hierarchical layout. https://arxiv.org/html/2311.00533 , https://eclipse.dev/elk/reference/algorithms/org-eclipse-elk-layered.html

### Maze (Lee), line-search, channel routing

The VLSI ancestors. The OVG + A* approach already subsumes Lee maze routing's guarantees at far lower cost (a sparse, geometry-driven graph instead of a dense pixel grid). The only borrowable piece is channel/track-assignment thinking for lanes, which the metro-line ordering literature covers more directly. No reason to move to a dense maze grid.

### Nudging and ordering of parallel wires (the lane problem)

After A* picks routes, connectors sharing a channel need (a) an ordering that minimizes crossings and only crosses at channel entry/exit (a metro-line crossing-minimization variant) and (b) a nudge pass that separates them by a fixed gap, solved as a 1-D separation-constraint problem. If the current lane logic is ad hoc, this is the second-highest-leverage upgrade after the 1-bend graph, and it is fully specified in GD 2009. Independent treatment: "Orthogonal Edge Routing for the EditLens", https://arxiv.org/pdf/1612.05064

### Incremental / selective reroute on drag

GD 2005 is the direct reference, and the app already implements its cheap half (reroute incident edges; drag tick and drop share a path; coalesce reroutes). Two refinements worth checking against the paper: also reconsider non-incident connectors that the moved node now blocks or frees (the bug case), and update the visibility graph locally on a move rather than rebuilding it (what keeps per-tick cost proportional to the affected region). Field note: per-event reroute is imperceptible for small graphs; 50+ nodes need debouncing/coalescing, which the app already does.

### Modern alternatives, honestly

- Force-directed edge bundling (Holten and van Wijk): curved bundles to reduce clutter in dense graphs. Wrong aesthetic and wrong problem.
- Sleeve routing (2026): CDT dual + funnel, batched per-source Dijkstra, scales to hundreds of thousands of edges at ~1.03x the visibility-graph optimum but produces polyline, not strictly orthogonal, routes and trades proven optimality for speed. Relevant only at extreme scale.
- Flow-based / ILP orthogonalization (topology-shape-metrics): optimal global bend minimization, but computes a whole-drawing orthogonal representation, not interactive per-drag rerouting of a fixed placement. Wrong interaction model.

## 2. C/C++ library options

| Library | Orthogonal obstacle-avoiding edge routing | Incremental / selective reroute | License | Closed-source-app fit | Build / Apple Silicon | Maturity |
|---|---|---|---|---|---|---|
| libavoid (Adaptagrams) | Yes, its core purpose; ports/pins, hyperedges | Yes, `SelectiveReroute` on by default, transaction model, per-connector | LGPL-2.1+ or paid commercial | Workable: dynamic-link or buy commercial license | Pure C++ + optional Cairo; Inkscape ships it universal on arm64 | High, single maintainer (Wybrow), active, release-less (vendor a commit) |
| OGDF | Partial: orthogonal drawing (layout+route together), no fixed-node router | No, batch global layout | GPL-2/3 + narrow exception | Blocker for closed source | CMake, C++17 | High, active |
| Graphviz | Weak: `splines=ortho` ignores ports; spline obstacle router emits Beziers | No, batch | EPL-2.0 (best license here) | Good license fit | autotools+CMake, Homebrew | Very high |
| libcola (Adaptagrams) | No, it is node layout, not routing | n/a | LGPL-2.1+ or commercial | n/a | with libavoid | High |

Notes:
- libavoid is the de-facto orthogonal connector router: Inkscape's connector tool is libavoid, ELK exposes it as `org.eclipse.elk.alg.libavoid`, Dunnart and various editors use it. It is the hardened version of the algorithm already in the app, with `Router`, `ShapeRef`, `ConnRef`, and `ShapeConnectionPin` for ports. https://www.adaptagrams.org/documentation/libavoid.html , https://github.com/mjwybrow/adaptagrams
- OGDF and Graphviz are batch layout engines without selective per-edge reroute; OGDF's GPL blocks commercial use; Graphviz's ortho mode ignores ports. yFiles, GoJS, mxGraph are commercial Java/JS/.NET toolkits, not embeddable C/C++.

## 3. Swift-native and Apple-framework options

Headline: nothing pure-Swift or Apple-supplied replaces the router. The ecosystem offers building blocks (a heap, a generic graph) or game-AI pathfinders that solve a different problem.

| Option | Type | License | Does orthogonal port-to-port + reroute? |
|---|---|---|---|
| libavoid (Adaptagrams) | Drop-in router (C++) | LGPL-2.1 | Yes, but C++, no Swift binding, LGPL linking question |
| GKObstacleGraph | Apple framework | system | No, any-angle navigation, not orthogonal wires |
| GKGridGraph | Apple framework | system | No, grid-cardinal A*, stair-steps, no bends/ports, slow at scale |
| swift-collections Heap/Deque/PriorityQueue | Building block | Apache 2.0 | No, best A* open-set/frontier primitive |
| tevelee/swift-graphs | Building block | MIT | No, generic A*/Dijkstra over a graph you build |
| davecom/SwiftGraph | Building block | Apache 2.0 | No, generic graph algos (Dijkstra), no A* |
| Bukk94/OrthogonalConnectorRouting | Reference algo (C#/WPF) | MIT | Algorithm yes, but no Swift port; study reference only |
| MapKit / PencilKit / SpriteKit / Accelerate | Apple frameworks | system | No, unrelated or arithmetic-only |

The one concrete, low-risk dependency worth taking regardless of the bigger decision is `swift-collections` `Heap`/`PriorityQueue` (Apache 2.0, Runtime Library Exception) for the A* open set. https://github.com/apple/swift-collections

## 4. Integration feasibility for libavoid (if it is ever chosen)

Technically feasible with strong precedent (Inkscape vendors the sources and ships universal macOS builds), but three things dominate, none of which is "can Swift call the C++":

1. License (LGPL-2.1). For a closed-source commercial macOS app, LGPL requires dynamic linking with a preserved relink path, which is awkward inside a sandboxed, notarized, signed app bundle. The clean options are: ship libavoid as a separate dynamic library with a documented relink path, or buy Wybrow's commercial license. This is likely the biggest gate and should be cleared first, with counsel.
2. Determinism. The app has golden-geometry tests (it even proved its own router is byte-deterministic across hash seeds and reversed input order). libavoid publishes no determinism guarantee. Pointer-keyed container iteration and cross-arch floating point are the usual drift sources. De-risk first with a tiny harness that routes a fixed graph repeatedly and across a clean rebuild and byte-compares output on Apple Silicon. If unstable, either quantize output before comparison (loosening the tests) or do not adopt.
3. The wrapping passes stay. libavoid replaces the core route step only. The port-marker, lane, and label passes still need to be re-anchored onto its output, which is the real engineering body of work.

Recommended integration shape: not direct Swift/C++ interop against libavoid's headers. Swift 6.2 C++ interop is real but version-fragile, and libavoid's API leans on owned pointers, transaction callbacks, and STL, which are the parts interop handles worst. Instead, a thin hand-written C or Objective-C++ (`.mm`) facade that exposes flat C structs (node rects, ports, edges in; polyline points out) and hides every C++ type. Vendor the sources and compile them as a Tuist/SPM C++ target the way Inkscape does (no autotools). Run routing off the main thread on the existing `HarnessMonitorAsyncWorkQueue`, one `Router` per diagram, never touched concurrently, results merged back on the MainActor.

Rough effort for a working in-process integration: about 3 to 4 weeks, with re-anchoring the surrounding passes and any determinism remediation being the parts that can overrun. Risk ranking: license, then determinism, then losing the wrapping-pass contract, then per-drag marshalling cost, then interop friction (near zero if shimmed).

Sources: https://www.swift.org/documentation/cxx-interop/ , https://www.swift.org/documentation/cxx-interop/status/ , https://github.com/mjwybrow/adaptagrams , https://eclipse.dev/elk/blog/posts/2022/22-11-17-libavoid.html , https://github.com/TypeFox/libavoid-server , https://github.com/clientIO/joint/discussions/3290

## 5. Decision guide

- If the goal is to fix specific routing defects (wires through bodies, crossings, lane crowding): refine the in-house router (1-bend graph, metro-line nudging, local incremental updates, the GD 2005 blocked-connector rule). Lowest risk, keeps determinism and full control of the port/lane/label passes, and survives any later library decision.
- If the goal is to stop maintaining the routing algorithm in-house: libavoid is the only credible target, but only after the LGPL question is cleared and determinism is proven on Apple Silicon, and with eyes open about re-anchoring the surrounding passes.
- Do not adopt OGDF (license), Graphviz (no ports, batch), ELK (layered model, Java), GameplayKit (wrong output), maze routing, edge bundling, or sleeve routing for this problem at this scale.

### Primary sources

- GD 2009 Orthogonal Connector Routing: https://users.monash.edu/~mwybrow/papers/wybrow-gd-2009.pdf
- Diagrams 2014 Seeing Around Corners (1-bend graph): https://users.monash.edu/~mwybrow/papers/marriott-diagrams-2014.pdf
- GD 2005 Incremental Connector Routing: https://ialab.it.monash.edu/~mwybrow/papers/wybrow-gd-2005.pdf
- libavoid / Adaptagrams: https://www.adaptagrams.org/documentation/libavoid.html , https://github.com/mjwybrow/adaptagrams
- ELK: https://arxiv.org/html/2311.00533 , https://eclipse.dev/elk/blog/posts/2022/22-11-17-libavoid.html
- EditLens orthogonal edge routing: https://arxiv.org/pdf/1612.05064
- Swift C++ interop: https://www.swift.org/documentation/cxx-interop/ , https://www.swift.org/documentation/cxx-interop/status/
- swift-collections: https://github.com/apple/swift-collections
- SwiftGraph: https://github.com/davecom/SwiftGraph , swift-graphs: https://github.com/tevelee/swift-graphs
- GameplayKit pathfinding: https://developer.apple.com/documentation/gameplaykit/gkobstaclegraph , https://developer.apple.com/documentation/gameplaykit/gkgridgraph
