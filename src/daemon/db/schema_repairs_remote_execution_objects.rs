use super::{CliError, db_error};

pub(super) fn expected_table_sql(migration_sql: &str, table: &str) -> Result<String, CliError> {
    extract_statement(migration_sql, &format!("CREATE TABLE {table} ("))
}

pub(super) fn expected_index_sql(migration_sql: &str, name: &str) -> Result<String, CliError> {
    let unique_header = format!("CREATE UNIQUE INDEX {name}");
    if has_exact_header(migration_sql, &unique_header) {
        return extract_statement(migration_sql, &unique_header);
    }
    extract_statement(migration_sql, &format!("CREATE INDEX {name}"))
}

pub(super) fn expected_trigger_sql(migration_sql: &str, name: &str) -> Result<String, CliError> {
    let header = format!("CREATE TRIGGER {name}");
    let Some(start) = statement_start(migration_sql, &header) else {
        return Err(missing_statement(&header));
    };
    let mut statement = String::new();
    for line in migration_sql.lines().skip(start) {
        statement.push_str(line);
        statement.push('\n');
        if line.trim() == "END;" {
            return Ok(normalize_statement(&statement));
        }
    }
    Err(unterminated_statement(&header))
}

fn extract_statement(sql: &str, header: &str) -> Result<String, CliError> {
    let Some(start) = statement_start(sql, header) else {
        return Err(missing_statement(header));
    };
    let mut statement = String::new();
    for line in sql.lines().skip(start) {
        statement.push_str(line);
        statement.push('\n');
        if line.trim_end().ends_with(';') {
            return Ok(normalize_statement(&statement));
        }
    }
    Err(unterminated_statement(header))
}

fn normalize_statement(statement: &str) -> String {
    let statement = statement.trim_end();
    let statement = statement.strip_suffix(';').unwrap_or(statement);
    super::schema_repairs::normalize_schema_sql(statement)
}

fn has_exact_header(sql: &str, header: &str) -> bool {
    statement_start(sql, header).is_some()
}

fn statement_start(sql: &str, header: &str) -> Option<usize> {
    sql.lines().position(|line| line.trim_end() == header)
}

fn missing_statement(header: &str) -> CliError {
    db_error(format!(
        "remote execution migration is missing statement '{header}'"
    ))
}

fn unterminated_statement(header: &str) -> CliError {
    db_error(format!(
        "remote execution migration statement '{header}' is unterminated"
    ))
}

#[cfg(test)]
mod tests {
    use super::expected_index_sql;

    #[test]
    fn index_extraction_requires_a_complete_name_match() {
        let sql = "CREATE INDEX task_board_remote_assignments_exact_attempt_history\n\
                   ON assignments(history);\n\
                   CREATE INDEX task_board_remote_assignments_exact_attempt\n\
                   ON assignments(attempt);";

        let statement = expected_index_sql(sql, "task_board_remote_assignments_exact_attempt")
            .expect("extract exact index");

        assert!(statement.contains("ON assignments(attempt)"));
        assert!(!statement.contains("ON assignments(history)"));
    }
}
