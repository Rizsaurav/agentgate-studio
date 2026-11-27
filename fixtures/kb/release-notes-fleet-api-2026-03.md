# Release Notes: Fleet API, March 2026

These notes describe the changes to the Orrinby Fleet API released on 10 March 2026. The Fleet API team publishes release notes every quarter. All changes are backwards compatible unless marked as breaking.

## Higher rate limits for Growth

The Growth plan limit has been raised from 300 to 600 requests per minute, and its daily quota from 150,000 to 250,000 requests. Starter and Enterprise limits are unchanged. No action is needed; the new limits applied automatically.

## Larger pages

The maximum page size for cursor pagination has been increased from 100 to 200 items. The default page size stays at 25 items.

## More webhook retries

Failed webhook deliveries are now retried up to 8 times over about 24 hours. Previously, deliveries were retried 5 times over 6 hours. Failed events can now also be resent manually from the dashboard for 7 days, up from 3 days.

## New events

- `bike.service_due` is sent when a bike reaches its service interval.
- `invoice.issued` is sent when a new invoice is available.

## New error codes

- OB-4003 is returned when a bike is in a service appointment and locked by the workshop.
- OB-3008 is returned when filters change while a cursor is reused. Previously, this case returned OB-3001.

## Breaking: personal access key expiry

Personal access keys created after 10 March 2026 expire after 90 days. Keys created earlier keep their original expiry of 365 days until 30 September 2026, after which they must be replaced.

## Deprecations

Version 1 of the API, including offset pagination on `GET /v1/orders`, is deprecated. The original shutdown date of 31 December 2026 has been moved to 30 June 2027 to give partners more time to migrate.

The `battery.critical` event is deprecated and replaced by `battery.alert`. It will stop being sent on 1 September 2026.

## Fixes

- Fixed `X-RateLimit-Reset` sometimes returning a negative number.
- Fixed `GET /rides` returning rides of bikes that had been removed from the account.
- Sandbox bikes now report realistic battery temperatures.

## Known issues

The `GET /reports/monthly` endpoint can take up to 30 seconds for fleets with more than 500 bikes. A fix is planned for the next release.
