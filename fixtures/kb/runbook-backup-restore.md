# Runbook: Backup and Restore

This runbook describes how Orrinby backs up production data and how to restore it. Owned by the Platform Reliability Group.

## What is backed up

| System                                        | Method                                                  | Frequency                     |
| --------------------------------------------- | ------------------------------------------------------- | ----------------------------- |
| `ledger-db` (orders, payments, subscriptions) | full snapshot plus continuous write-ahead log archiving | snapshot nightly at 02:00 UTC |
| `ride-db` (ride telemetry)                    | full snapshot                                           | nightly at 03:00 UTC          |
| Object storage (invoices, manuals, photos)    | versioned bucket replication                            | continuous                    |
| Weir configuration and feature flags          | export                                                  | every 6 hours                 |

## Retention

Nightly snapshots of `ledger-db` are kept for 35 days. The first snapshot of each month is kept for 12 months. Write-ahead logs are kept for 7 days, which allows point-in-time recovery to any second within the last 7 days.

`ride-db` snapshots are kept for 14 days only, because ride telemetry is itself deleted after 18 months under the privacy policy and does not need long-term backups.

All backups are encrypted and stored in a separate cloud account in a different region (Stockholm), so that a compromise of the production account cannot delete them. Backups are immutable for the first 7 days.

## Restore types

- **Point-in-time recovery (PITR)**: restore `ledger-db` to a specific moment, for example just before a bad migration. Run `orbctl db restore ledger-db --to "2026-05-04T10:15:00Z" --target ledger-db-restore`. A PITR restore of the full database takes about 90 minutes.
- **Snapshot restore**: restore a whole nightly snapshot to a new cluster. Takes about 60 minutes.
- **Single-table restore**: restore to a temporary cluster and copy the affected rows. Preferred when only some data is damaged.

Never restore directly over the production cluster. Restore to a new cluster, verify, and then switch endpoints or copy data back.

## Approvals

Restores into production require approval from the incident commander and one PRG engineer. Restores to a temporary cluster for investigation only need a ticket.

## Monthly restore test

On the first Tuesday of every month, the PRG on-call engineer restores the latest `ledger-db` snapshot to a temporary cluster and runs the integrity checks in `orbctl db verify`. Results are posted in #prg. A failed restore test is treated as a SEV3 incident.

## Personal data in backups

When a customer's account is deleted, their data remains in backups until those backups expire. Restored data must be re-checked against the deletion log so that deleted accounts are not brought back.
