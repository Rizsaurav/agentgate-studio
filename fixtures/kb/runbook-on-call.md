# Runbook: On-Call

This page describes how on-call works for Orrinby engineering teams: who is on call, how pages are handled, escalation and compensation.

## Rotations

Each production service has a primary and a secondary on-call engineer. Rotations last one week and hand over every Monday at 10:00 CET. The current rotations are:

- **Platform Reliability Group (PRG)**: infrastructure, databases, networking.
- **Checkout team**: online store, payments, Brevlin Finance integration.
- **Fleet API team**: Orrinby Fleet API and webhooks.
- **Ride team**: Orrinby Ride app backend and telemetry ingestion.

Engineers join a rotation after three months of employment and after shadowing one full rotation.

## Handover

At handover, the outgoing primary writes a short summary in #oncall-handover: open incidents, noisy alerts, planned maintenance. The incoming primary confirms they have read it.

## Responding to pages

Acknowledge a page within 10 minutes, at any time of day. (SEV1 incidents have a stricter 5-minute target, as defined in the Incident Response runbook.) If the primary does not acknowledge within 10 minutes, the page escalates automatically to the secondary. If the secondary does not acknowledge within a further 10 minutes, it escalates to the engineering manager of the team.

While on call, you must be able to reach a laptop with internet access within 15 minutes. You cannot be on call while travelling by air.

## Alerts

Every alert must link to a runbook. Alerts that page more than three times in a week without action are reviewed at the weekly reliability review and either fixed or downgraded to a ticket. Non-urgent alerts go to a ticket queue and are handled during business hours.

## Compensation

On-call engineers receive a weekly allowance of EUR 250 for the primary role and EUR 120 for the secondary role. Each out-of-hours page that requires more than 15 minutes of work is paid an additional EUR 60. Out-of-hours means before 08:00 or after 19:00 on weekdays, and all day on weekends and public holidays. Engineers who worked on an incident after midnight may start the next workday up to four hours later.

## Swaps and absences

Swap shifts in the on-call scheduler and announce it in the team channel. If you are sick while on call, tell your engineering manager, who finds a replacement. Nobody should be primary on call for more than two weeks in any six-week period.

## Health and limits

If you were paged more than five times in one night, hand over to the secondary for the following night. Teams that average more than ten out-of-hours pages per week for a month must schedule reliability work in their next planning cycle.
