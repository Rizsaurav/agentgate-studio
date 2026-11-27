# Runbook: Production Deploys

All Orrinby services are deployed with our internal deploy tool, Weir. This runbook covers deploy windows, approvals, canaries and rollbacks.

## Deploy windows

Production deploys are allowed Monday to Thursday between 09:00 and 16:00 CET, and on Friday between 09:00 and 13:00 CET. No production deploys are allowed on weekends or public holidays in Germany or the Netherlands.

A company-wide change freeze runs every year from 15 December to 5 January. During a freeze, only emergency fixes for SEV1 or SEV2 incidents may be deployed, with approval from the head of engineering.

## Approvals

Every change needs a pull request approved by at least one reviewer. Changes to payments, authentication or database schemas need two reviewers, one of whom must be from the owning team. Infrastructure changes to the Fleet API gateway need approval from the Platform Reliability Group.

## Canary process

Weir first deploys a new version to a canary that receives 5% of traffic. The canary runs for 20 minutes. Weir compares the canary with the stable version and promotes it automatically to 100% if:

- the error rate is below 1%, and
- the p95 latency is less than 10% higher than stable.

If a check fails, Weir halts the rollout and alerts the deployer. Do not override a halted canary without a second engineer's approval.

## Rollback

Roll back immediately, without investigation, if after a full rollout the error rate exceeds 2% for 5 minutes, or the p95 latency exceeds 800 ms for 10 minutes. Run `weir rollback <service>` to return to the previous version; rollbacks take about 3 minutes. Weir keeps the last 10 releases of each service available for rollback.

## Database migrations

Schema migrations run as a separate step before the application deploy. Migrations must be backwards compatible with the version currently running. Destructive migrations (dropping columns or tables) must wait at least 7 days after the code that stopped using them was deployed.

## Feature flags

New customer-facing features ship behind a feature flag in the Weir flag service. Flags must be removed within 30 days after the feature reaches 100% of users.

## After the deploy

Watch the service dashboard for 15 minutes after promotion. Announce the deploy in #deploys with the release number and a link to the pull request. If you deployed after 15:00, stay available until 17:00.
