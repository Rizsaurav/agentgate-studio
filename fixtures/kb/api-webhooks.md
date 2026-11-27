# Fleet API Reference: Webhooks

Webhooks let the Orrinby Fleet API notify your system when something happens, instead of you polling for changes. You need the `webhooks:manage` scope to create endpoints.

## Event types

| Event                           | Sent when                                           |
| ------------------------------- | --------------------------------------------------- |
| `ride.completed`                | a rider ends a ride and the ride has been processed |
| `battery.low`                   | a bike's battery drops below 15%                    |
| `battery.alert`                 | the battery reports a fault, such as overheating    |
| `bike.locked` / `bike.unlocked` | a bike is locked or unlocked, remotely or by key    |
| `bike.service_due`              | a bike reaches its service interval                 |
| `order.created`                 | a new order is placed on the Fleet account          |
| `invoice.issued`                | a new invoice is available                          |

Each account can register up to 20 webhook endpoints. Endpoints must use HTTPS.

## Payload

Every event is sent as a POST request with a JSON body containing `id`, `type`, `created_at` and a `data` object. Event IDs are unique; use them to ignore duplicates, because the same event can be delivered more than once.

## Verifying signatures

Each request includes an `X-Orrinby-Signature` header containing a timestamp and an HMAC-SHA256 signature of the timestamp and raw body, computed with your endpoint's signing secret. Reject requests where the signature does not match or the timestamp is more than 5 minutes old, to prevent replay attacks.

## Responding

Your endpoint must return a 2xx status within 10 seconds. Do the work asynchronously: store the event, respond, and process it later. Any other status, or no response within 10 seconds, counts as a failed delivery.

## Retries

Failed deliveries are retried up to 8 times over about 24 hours, with exponential backoff starting at 1 minute. After the last retry fails, the event is marked as failed and can be resent manually from the Fleet dashboard for 7 days.

If every delivery to an endpoint has failed for 3 consecutive days, the endpoint is disabled automatically and the account administrators receive an email. Re-enable it in the dashboard after fixing the problem.

## Ordering

Events are not guaranteed to arrive in order. Use `created_at` to order events, and fetch the current state from the API if order matters, for example for `bike.locked` and `bike.unlocked`.

## Testing

Use **Send test event** in the Fleet dashboard to deliver a sample of any event type. In the sandbox, simulated bikes generate `ride.completed` and `battery.low` events every few minutes.

## Rotating the signing secret

When you rotate an endpoint's signing secret, both the old and new secrets are used to sign requests for 24 hours. Each request then carries two signatures in the header.
