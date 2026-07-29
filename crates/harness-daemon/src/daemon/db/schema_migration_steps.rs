use super::super::{CliError, Connection};

pub(super) fn migrate_v9_to_v10(conn: &Connection) -> Result<(), CliError> {
    super::super::schema_v10::run(conn)
}

pub(super) fn migrate_v10_to_v11(conn: &Connection) -> Result<(), CliError> {
    super::super::schema_v11::run(conn)
}

pub(super) fn migrate_v11_to_v12(conn: &Connection) -> Result<(), CliError> {
    super::super::schema_v12::run(conn)
}

pub(super) fn migrate_v12_to_v13(conn: &Connection) -> Result<(), CliError> {
    super::super::schema_v13::run(conn)
}

pub(super) fn migrate_v13_to_v14(conn: &Connection) -> Result<(), CliError> {
    super::super::schema_v14::run(conn)
}

pub(super) fn migrate_v14_to_v15(conn: &Connection) -> Result<(), CliError> {
    super::super::schema_v15::run(conn)
}

pub(super) fn migrate_v15_to_v16(conn: &Connection) -> Result<(), CliError> {
    super::super::schema_v16::run(conn)
}

pub(super) fn migrate_v16_to_v17(conn: &Connection) -> Result<(), CliError> {
    super::super::schema_v17::run(conn)
}

pub(super) fn migrate_v17_to_v18(conn: &Connection) -> Result<(), CliError> {
    super::super::schema_v18::run(conn)
}

pub(super) fn migrate_v18_to_v19(conn: &Connection) -> Result<(), CliError> {
    super::super::schema_v19::run(conn)
}

pub(super) fn migrate_v19_to_v20(conn: &Connection) -> Result<(), CliError> {
    super::super::schema_v20::run(conn)
}

pub(super) fn migrate_v20_to_v21(conn: &Connection) -> Result<(), CliError> {
    super::super::schema_v21::run(conn)
}

pub(super) fn migrate_v21_to_v22(conn: &Connection) -> Result<(), CliError> {
    super::super::schema_v22::run(conn)
}

pub(super) fn migrate_v22_to_v23(conn: &Connection) -> Result<(), CliError> {
    super::super::schema_v23::run(conn)
}

pub(super) fn migrate_v23_to_v24(conn: &Connection) -> Result<(), CliError> {
    super::super::schema_v24::run(conn)
}

pub(super) fn migrate_v24_to_v25(conn: &Connection) -> Result<(), CliError> {
    super::super::schema_v25::run(conn)
}

pub(super) fn migrate_v25_to_v26(conn: &Connection) -> Result<(), CliError> {
    super::super::schema_v26::run(conn)
}

pub(super) fn migrate_v26_to_v27(conn: &Connection) -> Result<(), CliError> {
    super::super::schema_v27::run(conn)
}

pub(super) fn migrate_v27_to_v28(conn: &Connection) -> Result<(), CliError> {
    super::super::schema_v28::run(conn)
}

pub(super) fn migrate_v28_to_v29(conn: &Connection) -> Result<(), CliError> {
    super::super::schema_v29::run(conn)
}

pub(super) fn migrate_v29_to_v30(conn: &Connection) -> Result<(), CliError> {
    super::super::schema_v30::run(conn)
}

pub(super) fn migrate_v30_to_v31(conn: &Connection) -> Result<(), CliError> {
    super::super::schema_v31::run(conn)
}

pub(super) fn migrate_v31_to_v32(conn: &Connection) -> Result<(), CliError> {
    super::super::schema_v32::run(conn)
}

pub(super) fn migrate_v32_to_v33(conn: &Connection) -> Result<(), CliError> {
    super::super::schema_v33::run(conn)
}

pub(super) fn migrate_v33_to_v34(conn: &Connection) -> Result<(), CliError> {
    super::super::schema_v34::run(conn)
}

pub(super) fn migrate_v34_to_v35(conn: &Connection) -> Result<(), CliError> {
    super::super::schema_v35::run(conn)
}

pub(super) fn migrate_v35_to_v36(conn: &Connection) -> Result<(), CliError> {
    super::super::schema_v36::run(conn)
}

pub(super) fn migrate_v36_to_v37(conn: &Connection) -> Result<(), CliError> {
    super::super::schema_v37::run(conn)
}

pub(super) fn migrate_v37_to_v38(conn: &Connection) -> Result<(), CliError> {
    super::super::schema_v38::run(conn)
}

pub(super) fn migrate_v38_to_v39(conn: &Connection) -> Result<(), CliError> {
    super::super::schema_v39::run(conn)
}

pub(super) fn migrate_v39_to_v40(conn: &Connection) -> Result<(), CliError> {
    super::super::schema_v40::run(conn)
}

pub(super) fn migrate_v40_to_v41(conn: &Connection) -> Result<(), CliError> {
    super::super::schema_v41::run(conn)
}

pub(super) fn migrate_v41_to_v42(conn: &Connection) -> Result<(), CliError> {
    super::super::schema_v42::run(conn)
}

pub(super) fn migrate_v42_to_v43(conn: &Connection) -> Result<(), CliError> {
    super::super::schema_v43::run(conn)
}
