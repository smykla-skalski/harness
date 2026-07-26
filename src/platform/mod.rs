//! Empty. The kubectl-validate helper this held went with the hook guards that
//! were its only caller, and nothing replaced it. The module survives because
//! `layout::platform_module_stays_internal_to_the_crate` asserts the
//! `pub(crate) mod platform;` declaration in `src/lib.rs`; retiring the module,
//! that guard, and the `universal::platform_tests` suite together is follow-up
//! work rather than part of this deletion.
