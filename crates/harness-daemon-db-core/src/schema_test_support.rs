#[cfg(any(test, feature = "test-support"))]
use std::sync::{Arc, Mutex};

#[cfg(any(test, feature = "test-support"))]
type SchemaInitHook = dyn Fn() + Send + Sync + 'static;

#[cfg(any(test, feature = "test-support"))]
static SCHEMA_INIT_HOOK: Mutex<Option<Arc<SchemaInitHook>>> = Mutex::new(None);

/// # Panics
/// Panics if the schema init hook mutex is poisoned.
#[cfg(any(test, feature = "test-support"))]
pub fn set_schema_init_hook(hook: Option<Arc<SchemaInitHook>>) {
    *SCHEMA_INIT_HOOK
        .lock()
        .expect("schema init hook mutex poisoned") = hook;
}

pub(super) fn run_schema_init_hook() {
    #[cfg(any(test, feature = "test-support"))]
    if let Some(hook) = SCHEMA_INIT_HOOK
        .lock()
        .expect("schema init hook mutex poisoned")
        .clone()
    {
        hook();
    }
}
