# Claude OAuth persistence

Claude uses one OAuth token manager for inference, model discovery, validation,
and manual refresh. The API checks credentials at startup and every minute,
refreshing five minutes before expiry even when there are no inference requests.
After a machine shutdown or suspension it checks again when the process resumes.
No inference request is sent by the background scheduler.

## Proxy

Set `UNGATE_CLAUDE_PROXY_URL` in the API service environment to an HTTP(S) CONNECT
proxy. On this workstation it is `http://127.0.0.1:11889` (GOST). The dedicated
Undici 7.30.0 ProxyAgent handles code exchange, refresh, models and Claude requests.
With a configured proxy, connection failure never falls back to direct access.
Other providers retain their own transport settings.

When updating NSSM `AppEnvironmentExtra`, retain all existing entries. Restart
`ungate-api` to load the changed environment. The proxy must be available to the
service outside the browser session.

## States and recovery

`GET /auth/claude/status` keeps `authenticated`, `email` and `sessionExpired`, and
adds `state`, `expiresAt`, `lastRefreshAt`, `nextRetryAt` and `errorCode` (times are
Unix milliseconds). `POST /auth/claude/refresh` returns the same status without
credentials. The dashboard forwards it through its existing origin, loopback and
CSRF checks. Settings polls status every 15 seconds while visible.

| State | Meaning | Action |
| --- | --- | --- |
| `disconnected` | No saved credentials | Login |
| `ready` | Working access token | None |
| `refreshing` | One exchange is in progress | Wait |
| `retry_wait` | Temporary refresh failure, credentials retained | Wait for the displayed time or Retry now |
| `reauth_required` | Confirmed revocation, missing refresh token or uncertain exchange | Re-authorize |

Network failures known to precede sending, proxy unavailability, generic `403`,
`429` and `5xx` retain the pair and retry after 1, 5 and then 15 minutes, respecting
`Retry-After`. An unexpired access token can still serve requests during recovery.
An already-sent exchange with an unknown outcome is `refresh_uncertain`: its old
refresh token is never automatically replayed because the server may have rotated
it. The unexpired access token remains usable until expiry or a rejection.
Re-authorize to recover in this case. Confirmed `invalid_grant` and explicit token
revocation also require login.

SQLite stores the pair atomically. Every login and successful refresh creates a
new credential version; refresh results update only the version they started
with, so they cannot undo Logout or overwrite a newer login. A persisted
`refreshing` state after an interrupted process is treated as uncertain. Tokens
are removed only by explicit Logout. Diagnostics contain UTC time, error category,
HTTP status where available and result, without token values or OAuth bodies.

## Validation and deployment

Focused tests live in `apps/api/tests/integration/auth/claude-token-manager.test.ts`
and `claude-proxy.test.ts`. They cover rotation, omitted refresh tokens, metadata,
concurrent callers, logout/login races, CONNECT rejection, upstream failures,
timeout, incremental SSE, retry persistence, startup after downtime and 48 hours
of idle background refresh. Control tests cover refresh-route CSRF and origin
protection.

Build and bundle the API before restarting `ungate-api`; build the control bundle
before restarting `ungate-dashboard`. Preserve a SQLite backup before migration.
Never automatically restore an earlier database or credential pair after failure.
After Re-authorize, verify the manual refresh status, Claude model discovery and
a small Claude inference request. The old destructive handler may already have
deleted credentials; installation alone cannot recreate them.
