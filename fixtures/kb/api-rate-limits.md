# Fleet API Reference: Rate Limits

To keep the Orrinby Fleet API fast for everyone, requests are rate limited per account. All API clients and personal access keys of one account share the same limits.

## Limits per plan

| Plan       | Requests per minute | Requests per day | Burst                   |
| ---------- | ------------------- | ---------------- | ----------------------- |
| Starter    | 60                  | 10,000           | 10 requests per second  |
| Growth     | 600                 | 250,000          | 50 requests per second  |
| Enterprise | 3,000               | unlimited        | 200 requests per second |

The Fleet API plan is separate from the Orrinby Care plan: every Care Fleet customer starts on the Starter API plan and can upgrade in the Fleet dashboard. Sandbox requests have their own limit of 30 requests per minute, regardless of plan.

## How limits are counted

The per-minute limit uses a sliding 60-second window. The daily quota resets at 00:00 UTC. Token requests to `/oauth/token` count towards the per-minute limit but not the daily quota. Webhook deliveries from Orrinby to you do not count at all.

## Response headers

Every response includes:

- `X-RateLimit-Limit`: the per-minute limit for your plan.
- `X-RateLimit-Remaining`: requests left in the current window.
- `X-RateLimit-Reset`: seconds until the window has room again.
- `X-Quota-Remaining`: requests left today (not sent on Enterprise).

## When you exceed a limit

If you exceed the per-minute limit or the burst limit, the API returns HTTP 429 with error code OB-2001 and a `Retry-After` header in seconds. If you exceed the daily quota, the API returns HTTP 429 with error code OB-2002, and requests are blocked until the quota resets.

Clients should wait for the time in `Retry-After` and use exponential backoff with jitter. Clients that keep sending requests while limited for more than 10 minutes may be blocked for one hour.

## Expensive endpoints

Some endpoints count as more than one request:

| Endpoint                    | Cost        |
| --------------------------- | ----------- |
| `GET /rides/{id}/telemetry` | 5 requests  |
| `POST /bikes/bulk-update`   | 10 requests |
| `GET /reports/monthly`      | 20 requests |

## Raising your limits

Upgrade to a higher plan in the Fleet dashboard; the new limits apply within 5 minutes. Enterprise customers can request a temporary increase for planned events, such as onboarding a large fleet, by contacting their account manager at least 5 business days ahead.

## Best practices

Use webhooks instead of polling for ride and battery events. Use pagination with the largest page size you can handle. Cache bike details, which rarely change.
