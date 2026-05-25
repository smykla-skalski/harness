# App Store Privacy Labels

Use these App Store Connect privacy answers for Harness Monitor unless the implementation changes.

## Tracking

- Tracking: No
- Third-party advertising: No
- Developer advertising or marketing: No
- Third-party analytics: No by default

## Data Linked To The User

Declare these as collected for App Functionality and not used for tracking:

- Other User Content: mirrored session, task-board, review, transcript, diff, command, receipt, and station-health content.
- User ID: locally generated user- or account-level identifiers used for pairing, routing, signing, and replay protection.
- Device ID: locally generated station and device identifiers, public-key fingerprints, and CloudKit record routing identifiers.
- Product Interaction: command confirmations, queue state, lifecycle receipts, audit reasons, and sync status.

## Data Not Linked To The User

Declare this as collected for App Functionality and not used for tracking:

- Audio Data: voice input when voice capture features are used.

## Data Not Collected

Do not declare these because the v1 app does not collect them:

- Contact Info
- Health and Fitness
- Financial Info
- Location
- Sensitive Info
- Contacts
- Browsing History
- Search History
- Purchases
- Advertising Data
- Crash Data
- Performance Data
- Environment Scanning
- Hands
- Head
- Other Data Types

## Notes For Review

Harness Monitor uses private CloudKit records for user-owned sync. Encrypted payloads are opaque outside paired devices. The app does not provide raw remote desktop, shell streaming, or TUI streaming.

The CloudKit mirror export is intentionally auditable. It contains encrypted mirror records, visible routing metadata, encrypted-envelope fields, and a structured inventory with per-station counts, per-record-type counts, tombstone count, expiry range, and encrypted payload byte count. It does not expose plaintext session, review, command, transcript, or diff bodies.
