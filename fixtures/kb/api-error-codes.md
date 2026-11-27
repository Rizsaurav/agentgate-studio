# Fleet API Reference: Error Codes

When a request to the Orrinby Fleet API fails, the response has an HTTP status code and a JSON body with an Orrinby error code, a message and a request ID:

```json
{
  "error": {
    "code": "OB-3001",
    "message": "limit must be between 1 and 200",
    "request_id": "req_7Hc2kq"
  }
}
```

Always log the `request_id`; Fleet API support needs it to investigate. API error codes are not related to the E-codes shown on Halcy e-bike displays.

## Authentication errors (OB-1xxx)

| Code    | HTTP | Meaning                                          |
| ------- | ---- | ------------------------------------------------ |
| OB-1001 | 401  | Access token missing or malformed                |
| OB-1002 | 401  | Access token expired; request a new token        |
| OB-1003 | 403  | Token lacks the required scope                   |
| OB-1004 | 401  | Client secret or personal access key revoked     |
| OB-1005 | 403  | Request from an IP address outside the allowlist |

## Limit errors (OB-2xxx)

| Code    | HTTP | Meaning                                 |
| ------- | ---- | --------------------------------------- |
| OB-2001 | 429  | Per-minute or burst rate limit exceeded |
| OB-2002 | 429  | Daily quota exceeded                    |
| OB-2003 | 402  | Feature not included in your API plan   |

## Request errors (OB-3xxx)

| Code    | HTTP | Meaning                                                 |
| ------- | ---- | ------------------------------------------------------- |
| OB-3001 | 400  | Validation failed; the message names the field          |
| OB-3002 | 400  | Malformed JSON body                                     |
| OB-3004 | 404  | Resource not found, or not visible to your account      |
| OB-3005 | 409  | Conflict: the bike is already assigned to another rider |
| OB-3006 | 409  | Idempotency key reused with a different request body    |
| OB-3007 | 400  | Pagination cursor expired                               |
| OB-3008 | 400  | Pagination filters changed while reusing a cursor       |

## Bike state errors (OB-4xxx)

| Code    | HTTP | Meaning                                                     |
| ------- | ---- | ----------------------------------------------------------- |
| OB-4001 | 409  | Bike is offline; the command was queued for up to 24 hours  |
| OB-4002 | 409  | Bike is moving; remote lock refused                         |
| OB-4003 | 423  | Bike is in a service appointment and locked by the workshop |

## Server errors (OB-5xxx)

| Code    | HTTP | Meaning                                                         |
| ------- | ---- | --------------------------------------------------------------- |
| OB-5001 | 500  | Internal error                                                  |
| OB-5003 | 503  | Service temporarily unavailable, for example during maintenance |

Retry OB-5001 and OB-5003 with exponential backoff, at most 5 times. Do not retry OB-3xxx errors without changing the request.

## Idempotency

POST requests accept an `Idempotency-Key` header. Orrinby stores the key and the response for 24 hours. Repeating the same request with the same key returns the stored response instead of performing the action again.
