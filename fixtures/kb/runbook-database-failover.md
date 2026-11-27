# Runbook: Database Failover

This runbook covers failover of `ledger-db`, the primary PostgreSQL cluster that stores orders, payments and subscriptions. It is owned by the Platform Reliability Group. Use it only during an incident with an assigned incident commander.

## Topology

`ledger-db` runs one primary and two streaming replicas in the Frankfurt region, plus one asynchronous replica in the Amsterdam region for disaster recovery. Application services connect through the `ledger-db-rw` endpoint for writes and `ledger-db-ro` for reads.

The recovery point objective (RPO) for `ledger-db` is 1 minute and the recovery time objective (RTO) is 15 minutes.

## When to fail over

Fail over to a Frankfurt replica if the primary is unreachable for more than 2 minutes, or if the primary's disk is failing. Fail over to Amsterdam only if the whole Frankfurt region is unavailable; this is a regional failover and requires approval from both the incident commander and the head of engineering.

Do not fail over because of slow queries or high CPU alone; investigate those first.

## Pre-checks

1. Confirm the primary is really down from two different hosts.
2. Check replica lag with `orbctl db lag ledger-db`. Choose the replica with the lowest lag.
3. If replica lag is above 30 seconds, tell the incident commander, because recent transactions may be lost.

## Failover steps

1. Freeze writes: `orbctl db freeze ledger-db`. Checkout shows a maintenance page.
2. Promote the chosen replica: `orbctl db promote ledger-db --replica <name>`.
3. Point `ledger-db-rw` at the new primary: `orbctl db switch-endpoint ledger-db`. DNS TTL is 30 seconds.
4. Unfreeze writes: `orbctl db unfreeze ledger-db`.
5. Verify with a test order in the internal test shop.

A regional failover to Amsterdam uses the same commands with `--region ams`, and takes about 25 minutes because the asynchronous replica must be checked for missing transactions first.

## After failover

Rebuild the old primary as a new replica; never bring it back as primary without a full resynchronisation. Reconcile payments against the payment processor's settlement report for the period from 10 minutes before the failure until writes resumed. Record the measured data loss and downtime in the incident record.

## Drills

A failover drill is run every quarter on the staging cluster and twice a year on production during the deploy window. The last drill must have met the 15-minute RTO; if it did not, the failover procedure is reviewed before the next quarter.

## Related

Backups and point-in-time recovery are described in the Backup and Restore runbook.
