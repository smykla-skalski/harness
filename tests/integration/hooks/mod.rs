// Hook guard/verify integration tests.
// Split by hook type: guard_bash, guard_write, guard_question,
// verify (bash/write/question combined), audit.

mod audit;
mod guard_bash;
mod guard_question;
mod guard_write;
mod verify;
