//! Normalized policy-graph storage. The database is the source of truth for
//! policy canvases; `mapper` converts between the domain `PolicyGraph` /
//! `PolicyCanvasRecord` / `PolicyCanvasWorkspace` and the row structs in `rows`.

// TEMPORARY: the row/mapper layer lands before its callers (`store_async` and
// the `PolicyPipelineStore` rewrite) in this workstream. Removed once those wire
// the CRUD through; the WS8 clean-up gate verifies no `allow(dead_code)` remains.
#![allow(dead_code)]

mod mapper;
mod rows;
mod sql;
mod store_async;
mod store_sync;
