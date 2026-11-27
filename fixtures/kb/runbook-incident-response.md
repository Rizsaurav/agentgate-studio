# Runbook: Incident Response

This runbook describes how Orrinby engineering handles production incidents affecting the online store, the Orrinby Ride app backend or the Orrinby Fleet API. It is owned by the Platform Reliability Group (PRG).

## Severity levels

| Severity | Definition                                                                         | Example                                   |
| -------- | ---------------------------------------------------------------------------------- | ----------------------------------------- |
| SEV1     | Complete outage of checkout, payments or the Fleet API, or a confirmed data breach | Checkout returns errors for all customers |
| SEV2     | Major feature degraded for many customers, no workaround                           | Ride app cannot sync rides                |
| SEV3     | Minor feature degraded, workaround exists                                          | Order history slow to load                |
| SEV4     | Cosmetic issue or internal tooling problem                                         | Typo on the status page                   |

When unsure, declare the higher severity. Severity can be lowered later; under-declaring delays help.

## Declaring an incident

Anyone can declare an incident by typing `/incident declare` in the #ops-alerts chat channel. The bot creates a dedicated channel named `#inc-YYYYMMDD-short-name`, pages the on-call engineer and opens an incident record.

For SEV1, the on-call engineer must acknowledge within 5 minutes, and an incident commander must be assigned within 15 minutes. For SEV2, acknowledgement is required within 15 minutes. SEV3 and SEV4 are handled during business hours.

## Roles

- **Incident commander (IC)**: coordinates the response, makes decisions, keeps the timeline. The IC does not debug.
- **Operations lead**: investigates and applies fixes.
- **Communications lead**: updates the status page and Customer Care.
- **Scribe**: records actions and timestamps in the incident record.

For SEV1, all four roles must be filled by different people. For SEV2, the IC may also act as communications lead.

## Communication cadence

The public status page must be updated every 30 minutes during a SEV1 and every 60 minutes during a SEV2, even if there is no news. Customer Care receives the same updates through the #care-escalations channel. If a SEV1 lasts longer than 2 hours, the IC informs the Chief Technology Officer by phone.

## Mitigation first

Restore service before finding the root cause. Preferred mitigations, in order: roll back the last deploy, disable the feature flag, fail over to the secondary region, scale up. Database failover follows the Database Failover runbook and needs approval from the IC.

## Security incidents

If personal data may have been exposed, the IC must involve the Data Protection Officer within 1 hour. A personal data breach must be reported to the supervisory authority within 72 hours of becoming aware of it, so the DPO decides early whether notification is needed.

## Closing an incident

An incident is resolved when customer impact has ended and monitoring has been stable for 30 minutes. The IC posts a final status page update and closes the channel topic.

## Postmortems

A blameless postmortem is required for every SEV1 and SEV2. The draft must be shared within 5 business days of resolution and reviewed in the weekly reliability review on Thursday. Action items get an owner and a due date and are tracked in the PRG backlog. SEV3 incidents need only a short summary in the incident record.
