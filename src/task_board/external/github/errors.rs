use crate::errors::{CliError, CliErrorKind};

pub(super) fn github_sync_error_with_context(
    context: impl Into<String>,
    error: CliError,
) -> CliError {
    let context = context.into();
    let summary = error.message();
    let details = error.details().map(ToOwned::to_owned);
    let message = format!("task-board github sync failed while {context}: {summary}");
    warn_github_message(&message);
    let mut cli_error = CliError::new(CliErrorKind::workflow_io(message));
    if let Some(details) = details {
        cli_error = cli_error.with_details(details);
    }
    cli_error
}

pub(super) fn warn_github_message(message: &str) {
    use tracing::callsite::{DefaultCallsite, Identifier};
    use tracing::field::{FieldSet, Value};
    use tracing::metadata::Kind;
    use tracing::{Event, Level, Metadata};

    static FIELDS: &[&str] = &["message"];
    static CALLSITE: DefaultCallsite = DefaultCallsite::new(&META);
    static META: Metadata<'static> = Metadata::new(
        "warn",
        "harness::task_board::external::github",
        Level::WARN,
        Some(file!()),
        Some(line!()),
        Some(module_path!()),
        FieldSet::new(FIELDS, Identifier(&CALLSITE)),
        Kind::EVENT,
    );

    let values: &[Option<&dyn Value>] = &[Some(&message)];
    Event::dispatch(&META, &META.fields().value_set_all(values));
}
