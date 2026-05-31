//! Normalized policy-graph storage. The database is the source of truth for
//! policy canvases; `mapper` converts between the domain `PolicyGraph` /
//! `PolicyCanvasRecord` / `PolicyCanvasWorkspace` and the row structs in `rows`.

mod mapper;
mod rows;
mod sql;
mod store_async;
mod store_sync;
