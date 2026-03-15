# Evaluation data

Test cases for validating suite:new output quality.

## Structure

Each eval is a directory with:
- `input.md` - feature name, flags, and repo state description
- `expected.md` - expected suite structure, group count, and key manifest patterns
- `criteria.md` - pass/fail criteria for the generated suite

## Running

Manual comparison: run the skill with the input, diff output against expected.
