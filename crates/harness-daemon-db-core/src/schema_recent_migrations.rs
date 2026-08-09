use super::{CliError, DaemonDb};

impl DaemonDb {
    pub(super) fn apply_pending_migrations_v57_to_v71(
        &self,
        version_number: u8,
    ) -> Result<(), CliError> {
        if version_number <= 56 {
            harness_db_schema::schema_v57::run(&self.conn)?;
        }
        if version_number <= 57 {
            harness_db_schema::schema_v58::run(&self.conn)?;
        }
        if version_number <= 58 {
            harness_db_schema::schema_v59::run(&self.conn)?;
        }
        if version_number <= 59 {
            harness_db_schema::schema_v60::run(&self.conn)?;
        }
        if version_number <= 60 {
            harness_db_schema::schema_v61::run(&self.conn)?;
        }
        if version_number <= 61 {
            harness_db_schema::schema_v62::run(&self.conn)?;
        }
        if version_number <= 62 {
            harness_db_schema::schema_v63::run(&self.conn)?;
        }
        if version_number <= 63 {
            harness_db_schema::schema_v64::run(&self.conn)?;
        }
        if version_number <= 64 {
            harness_db_schema::schema_v65::run(&self.conn)?;
        }
        if version_number <= 65 {
            harness_db_schema::schema_v66::run(&self.conn)?;
        }
        if version_number <= 66 {
            harness_db_schema::schema_v67::run(&self.conn)?;
        }
        if version_number <= 67 {
            harness_db_schema::schema_v68::run(&self.conn)?;
        }
        if version_number <= 68 {
            harness_db_schema::schema_v69::run(&self.conn)?;
        }
        if version_number <= 69 {
            harness_db_schema::schema_v70::run(&self.conn)?;
        }
        if version_number <= 70 {
            harness_db_schema::schema_v71::run(&self.conn)?;
        }
        Ok(())
    }
}
