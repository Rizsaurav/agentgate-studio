# Fleet API Reference: Pagination

List endpoints in the Orrinby Fleet API, such as `GET /bikes`, `GET /rides` and `GET /orders`, return results in pages. Version 2 of the API uses cursor-based pagination.

## Cursor pagination

Each list response contains a `data` array and a `pagination` object:

```json
{
  "data": [ ... ],
  "pagination": {
    "next_cursor": "c2VxOjE0MDI=",
    "has_more": true
  }
}
```

To fetch the next page, pass the value of `next_cursor` as the `cursor` query parameter. When `has_more` is false, you have reached the last page and `next_cursor` is null.

## Page size

Use the `limit` query parameter to choose the page size. The default page size is 25 items. The maximum page size is 200 items; larger values are rejected with error OB-3001. The `GET /rides/{id}/telemetry` endpoint is an exception: it returns telemetry points with a default of 500 and a maximum of 5,000 per page.

## Cursor lifetime

Cursors are opaque strings; do not try to decode or build them. A cursor stays valid for 24 hours after it was issued. Using an expired cursor returns error OB-3007, and you must restart from the first page.

## Ordering

Results are sorted by creation time, newest first, unless you pass `order=asc`. Sorting by other fields is not supported. Items created while you page through results may not appear; items are never returned twice.

## Filtering

Most list endpoints accept filters, for example `GET /rides?bike_id=...&from=2026-01-01`. Filters must be the same on every page request. Changing filters while reusing a cursor returns error OB-3008.

## Total counts

Responses do not include a total count, because counting large collections is slow. If you need a count, use `GET /reports/monthly`, which includes totals per month.

## Legacy offset pagination

Version 1 of the API used offset pagination with `offset` and `limit` parameters. Offset pagination still works on `GET /v1/orders` but is deprecated: the maximum offset is 10,000, and the maximum page size is 100. Version 1 will be switched off on 30 June 2027. Migrate to cursor pagination in version 2.

## Example

To list all bikes with 100 per page:

1. `GET /bikes?limit=100`
2. Read `pagination.next_cursor` from the response.
3. `GET /bikes?limit=100&cursor=<next_cursor>`
4. Repeat until `has_more` is false.

Each page request counts as one request towards your rate limit.
