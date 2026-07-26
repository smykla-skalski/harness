// Hook guard/verify integration tests.
// Split by hook type: guard_bash, guard_write, guard_question, and verify,
// which now covers verify-question only.

mod guard_bash;
mod guard_question;
mod guard_write;
mod verify;
