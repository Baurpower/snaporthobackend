# SnapOrtho notification runbook

## Required production configuration

Set `SUPABASE_DATABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `ADMIN_API_KEY`,
`APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_BUNDLE_ID`, and `APNS_ENVIRONMENT`.

Private key (one of):

- `APNS_KEY_PATH` — path to the `.p8` file inside the runtime container
- `APNS_PRIVATE_KEY` — PEM contents (multiline or single-line with `\n`; base64-of-PEM also accepted)

`APNS_ENVIRONMENT` is the **default** environment (`production` or `sandbox`).
The process configures **both** sandbox and production APNs clients with the same
signing credentials. Endpoint selection is always driven by the registration row’s
`environment` column — never by guessing or by a single fixed client alone.

`APNS_BUNDLE_ID` must be `com.alexbaur.Snap-Ortho` for the current app target.

Never put secret values, raw device tokens, authorization headers, or notification
content containing PHI in logs or tickets.

## Database source of truth

| Item | Value |
|------|--------|
| Table | `user_device_tokens` (Supabase Postgres via Fluent DB id `.notifications`) |
| Model | `UserDeviceToken` |
| Unique key | `(token_hash, environment)` |
| Token storage | plaintext `token` + SHA-256 `token_hash` |
| Environments | `sandbox` \| `production` (CHECK constraint) |
| Delivery log | `notification_delivery_attempts` |

Legacy Amazon RDS `devices` is best-effort dual-write only and is **not** used for sends.

## Exact-device smoke test

1. Install a signed build on a physical device and confirm the embedded
   `aps-environment` entitlement. Development builds register as `sandbox`;
   TestFlight/App Store builds register as `production`.
2. Sign in, grant notifications, and confirm the backend records one active row
   with the expected user, environment, `receive_notifications=true`.
3. List masked candidates (admin):

```bash
curl -sS -H "X-Admin-Key: $ADMIN_API_KEY" \
  "https://api.snap-ortho.com/admin/notifications/registrations?environment=sandbox&limit=20"
```

4. Send to **one exact** registration UUID (preferred):

```bash
curl -sS -X POST "https://api.snap-ortho.com/admin/push/test" \
  -H "X-Admin-Key: $ADMIN_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "registrationId": "<exact registration UUID>",
    "title": "SnapOrtho Test",
    "body": "APNs test notification",
    "deeplink": "snaportho://notifications/test"
  }'
```

Legacy alternative (exact raw token + environment):

```bash
curl -sS -X POST "https://api.snap-ortho.com/admin/notifications/test" \
  -H "X-Admin-Key: $ADMIN_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "deviceToken": "<64-char hex>",
    "environment": "sandbox",
    "title": "SnapOrtho Test",
    "body": "APNs test notification",
    "deeplink": "snaportho://notifications/test"
  }'
```

5. Require `target_count=1` in the pre-send log. Stop if the target is inactive,
   opted out, invalidated, or its environment is not configured.
6. Check `notification_delivery_attempts` for status, `apns_id`, and metadata
   (`apns_environment`, `apns_topic`, `registration_disabled`).
   HTTP 200 means the backend completed the send path and APNs accepted the request.
   Device display is a separate confirmation step.

### What the exact test route rejects

- Missing `registrationId`
- Unknown `registrationId`
- Disabled / invalidated registration
- `receive_notifications = false`
- Unknown or unconfigured APNs environment
- Never falls back to another device or “first row in the table”

## Diagnostics

- `BadDeviceToken` / `Unregistered` / `DeviceTokenNotForTopic`: registration is disabled; do not retry that row.
- `ExpiredProviderToken` / `InvalidProviderToken` / `TooManyProviderTokenUpdates`: fix key/team IDs; do not disable devices.
- `MissingTopic` / `TopicDisallowed`: verify bundle ID and key capabilities.
- Rate limit, timeout, network, TLS, APNs 5xx: transient; do not disable.

## Scheduled delivery

`CandidateSchedulerJob` maintains candidate state but does not dispatch pending
rows. Candidate generation and `process-scheduled-notifications` are currently
operator-invoked commands. Never test scheduling through the broadcast route.

## EC2 verification (safe)

```bash
# Deployed commit (adjust path to your checkout)
cd /path/to/snaporthobackend && git rev-parse HEAD

# Service status (name may vary — inspect with systemctl list-units | grep -i vapor)
systemctl status snaportho-backend   # or docker compose ps

# Confirm APNs env vars are present without printing values
printenv | grep -E '^(APNS_|ADMIN_API_KEY|SUPABASE_DATABASE_URL)=' | sed 's/=.*/=<set>/'

# Key file exists and is readable by the service user
sudo -u vapor test -r "${APNS_KEY_PATH:-/etc/apns/AuthKey_*.p8}" && echo key_readable=yes

# Clock skew (JWT auth fails if server time is badly wrong)
date -u; timedatectl status 2>/dev/null | head -5

# Outbound APNs reachability (TLS only — does not send a push)
curl -sS -o /dev/null -w "%{http_code}\n" --connect-timeout 5 https://api.push.apple.com
curl -sS -o /dev/null -w "%{http_code}\n" --connect-timeout 5 https://api.sandbox.push.apple.com

# Recent APNs / registration logs (redact tokens if any appear)
journalctl -u snaportho-backend -n 200 --no-pager | grep -E 'APNS|device/register|notification_presend|Admin exact' | tail -50

# Restart after config changes
sudo systemctl restart snaportho-backend
# or: docker compose restart app
```

### Inspect registrations in Supabase (SQL)

```sql
SELECT
  id AS registration_id,
  user_id,
  environment,
  platform,
  receive_notifications,
  invalidated_at IS NULL AS enabled,
  left(token, 8) || '…' || right(token, 4) AS masked_token,
  left(token_hash, 12) AS token_hash_prefix,
  app_version,
  last_seen_at,
  created_at,
  updated_at
FROM user_device_tokens
WHERE invalidated_at IS NULL
ORDER BY last_seen_at DESC
LIMIT 50;

SELECT environment, count(*) FILTER (WHERE invalidated_at IS NULL) AS active
FROM user_device_tokens
GROUP BY environment;
```

### Confirm a send attempt

```sql
SELECT
  id,
  device_token_id,
  status,
  apns_id,
  error_code,
  error_message,
  metadata,
  created_at,
  sent_at
FROM notification_delivery_attempts
WHERE device_token_id = '<registration uuid>'
ORDER BY created_at DESC
LIMIT 5;
```

## Deployment and rollback

Record the deployed Git SHA, run the health endpoint (`GET /`), and inspect
startup logs for:

```text
✅ APNS configured default=… configured=[production,sandbox] topic=com.alexbaur.Snap-Ortho
✅ Supabase notifications DB configured
```

Rollback by redeploying the previous known-good image/SHA. Do not drop notification tables.
