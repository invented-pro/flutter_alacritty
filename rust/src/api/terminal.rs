// Re-export the engine + snapshot types so FRB bridges them.
// TerminalEngine becomes a Dart opaque class with methods;
// RenderSnapshot/CellData become mirrored Dart data classes.
pub use crate::engine::{CellData, RenderSnapshot, TerminalEngine};

use flutter_rust_bridge::frb;

#[frb(sync)]
pub fn engine_new(columns: u16, rows: u16) -> TerminalEngine {
    TerminalEngine::new(columns, rows)
}

#[frb(sync)]
pub fn engine_advance(engine: &mut TerminalEngine, bytes: Vec<u8>) {
    engine.advance(bytes);
}

#[frb(sync)]
pub fn engine_snapshot(engine: &TerminalEngine) -> RenderSnapshot {
    engine.snapshot()
}

#[frb(sync)]
pub fn engine_resize(engine: &mut TerminalEngine, columns: u16, rows: u16) {
    engine.resize(columns, rows);
}
