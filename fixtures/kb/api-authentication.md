# Fleet API Reference: Authentication

The Orrinby Fleet API lets business customers with Care Fleet subscriptions manage their e-bikes, read ride data and receive webhook events. This page explains how to authenticate. The base URL for all requests is `https://api.orrinby.example/v2`.

## Credentials

Each Fleet account can create API clients in the Fleet dashboard under **Developers > API clients**. An API client has a client ID and a client secret. The secret is shown only once, when the client is created; if you lose it, rotate the secret.

Each account may have up to 10 active API clients. Test clients work only against the sandbox at `https://sandbox.api.orrinby.example/v2`, which contains simulated bikes and never charges for usage.

## Obtaining an access token

The Fleet API uses the OAuth 2.0 client credentials flow. Send a POST request to `/oauth/token` with your client ID, client secret and the scopes you need. The response contains an access token.

Access tokens expire after 3600 seconds (one hour). Request a new token before the old one expires; do not request a new token for every API call, as token requests count towards your rate limit. There are no refresh tokens in the client credentials flow.

## Personal access keys

For scripts and quick tests, account administrators can create personal access keys instead of API clients. Live keys start with `obk_live_` and sandbox keys start with `obk_test_`. Personal access keys expire after 90 days and can be revoked at any time. They are sent in the `Authorization: Bearer` header just like access tokens.

## Scopes

| Scope             | Allows                                             |
| ----------------- | -------------------------------------------------- |
| `fleet:read`      | list bikes, read bike status and battery state     |
| `fleet:write`     | rename bikes, assign riders, lock and unlock bikes |
| `rides:read`      | read ride history and telemetry                    |
| `orders:read`     | read orders and invoices                           |
| `webhooks:manage` | create and delete webhook endpoints                |

Request only the scopes you need. A request without the required scope fails with error OB-1003.

## Remote lock

Locking or unlocking a bike with `fleet:write` also requires the `X-Orrinby-Confirm: true` header, as a guard against accidental calls. Remote lock only works when the bike is stationary.

## IP allowlist

Enterprise accounts can restrict API access to an IP allowlist of up to 50 CIDR ranges. Requests from other addresses fail with error OB-1005.

## Rotating secrets

Rotate client secrets at least every 12 months. When you rotate, the old secret remains valid for 24 hours so you can deploy the new one without downtime.

## Security recommendations

Never put client secrets or personal access keys in mobile apps, browser code or public repositories. If a secret is exposed, revoke it immediately in the dashboard; revocation takes effect within 60 seconds.
