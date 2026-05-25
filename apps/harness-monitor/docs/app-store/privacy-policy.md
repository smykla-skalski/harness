# Harness Monitor Privacy Policy

Effective date: May 25, 2026

Harness Monitor is a remote attention cockpit for Harness work running on your Mac. The iPhone, Apple Watch, widgets, and Live Activities show mirrored Monitor state and let you send signed work commands back to a trusted Mac.

## Data We Handle

Harness Monitor handles these categories of data for app functionality:

- Other user content: session titles, task-board text, review summaries, file paths, diffs, transcript snippets, command text, command receipts, and station health messages that your Mac mirrors for mobile use.
- Identifiers: locally generated station IDs, device IDs, public-key fingerprints, and CloudKit record IDs used for pairing, encryption, command signing, replay protection, and multi-station routing.
- Product interaction: command lifecycle state, confirmations, audit reasons, queue state, and sync status needed to execute and audit user-requested commands.
- Audio data: voice input when you use voice capture features.

Harness Monitor does not mirror credentials, tokens, environment secrets, raw authentication files, private keys, or raw terminal streams.

## Storage And Sync

Live mobile sync uses your private iCloud CloudKit database. The Mac writes encrypted mirror records, and paired iPhone and Apple Watch devices read those records. Mobile devices write signed command records, and the Mac writes immutable receipts.

CloudKit keeps clear metadata needed for routing, including record type, station ID, schema version, revision, update time, expiry, tombstone state, and chunk IDs. The encrypted-envelope fields also remain visible as opaque cryptographic material: algorithm, key ID, nonce, ciphertext, authentication tag, additional authenticated data, and envelope creation time. Titles, statuses, transcripts, diffs, reviews, commands, receipts, and event bodies are encrypted before they are written to CloudKit.

Mirrored CloudKit records expire after seven days by default. Users can export or delete mirrored records from iPhone Settings in the app.

## Tracking, Ads, And Analytics

Harness Monitor does not track users across apps or websites. It has no ads and no third-party analytics by default. Data is collected only for app functionality.

## Demo Mode

Demo mode uses built-in sample data for App Review, screenshots, previews, and no-Mac evaluation. Demo data is not your live Harness data.

## User Choices

You can:

- Pair or unpair trusted Macs and mobile devices.
- Export mirrored CloudKit records from iPhone Settings. The export includes encrypted record payloads plus a structured inventory with station counts, record-type counts, tombstone count, expiry range, and encrypted byte count.
- Delete mirrored CloudKit records from iPhone Settings. The delete action returns a structured deletion report before local mobile/watch caches are cleared.
- Disable notifications in the app or in system Settings.
- Use Demo mode without connecting to a Mac.

## Contact

For privacy questions or deletion help, contact bartek@smykla.com.
