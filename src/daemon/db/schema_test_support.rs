#[cfg(test)]
use std::sync::{Arc, Mutex};

#[cfg(test)]
type SchemaInitHook = dyn Fn() + Send + Sync + 'static;

#[cfg(test)]
static SCHEMA_INIT_HOOK: Mutex<Option<Arc<SchemaInitHook>>> = Mutex::new(None);

#[cfg(test)]
pub(crate) fn set_schema_init_hook(hook: Option<Arc<SchemaInitHook>>) {
    *SCHEMA_INIT_HOOK
        .lock()
        .expect("schema init hook mutex poisoned") = hook;
}

pub(super) fn run_schema_init_hook() {
    #[cfg(test)]
    if let Some(hook) = SCHEMA_INIT_HOOK
        .lock()
        .expect("schema init hook mutex poisoned")
        .clone()
    {
        hook();
    }
}
