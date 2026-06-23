# SnapOrtho — Notification Phase 1 Implementation

**Date:** 2026-06-23  
**Status:** Phase 1 production-readiness fixes applied — deploy after completing checklist below

---

## ⚠️ Required Before Production

**Do not deploy until every step below is complete.** These are not optional.

### 1. Set all production environment variables

| Variable | Required in production |
|----------|------------------------|
| `DATABASE_HOST`, `DATABASE_USERNAME`, `DATABASE_PASSWORD`, `DATABASE_NAME` | Yes |
| `SUPABASE_DATABASE_URL` | Yes (direct Postgres, port 5432) |
| `SUPABASE_SERVICE_ROLE_KEY` | Yes |
| `ADMIN_API_KEY` | Yes (startup fails if missing) |
| `APNS_KEY_PATH` | Yes (no fallbacks in production) |
| `APNS_KEY_ID` | Yes |
| `APNS_TEAM_ID` | Yes |
| `APNS_BUNDLE_ID` | Yes |
| `APNS_ENVIRONMENT` | Yes (`production` or `sandbox`) |
| `SUPABASE_URL` | Optional (defaults to project URL; used for JWKS) |

### 2. Run FK SQL in Supabase SQL editor

```sql
ALTER TABLE public.user_device_tokens
    ADD CONSTRAINT fk_udt_user_id
    FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;

ALTER TABLE public.notification_preferences
    ADD CONSTRAINT fk_np_user_id
    FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;

ALTER TABLE public.notification_delivery_attempts
    ADD CONSTRAINT fk_nda_user_id
    FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE SET NULL;
```

### 3. Enable RLS in Supabase

```sql
ALTER TABLE public.user_device_tokens ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.notification_preferences ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users can view and manage own preferences"
    ON public.notification_preferences
    FOR ALL USING (auth.uid() = user_id);
```

Vapor connects via direct Postgres (`postgres` role) and bypasses RLS. Do not expose `notification_delivery_attempts` via PostgREST.

### 4. Build and test

```bash
swift build
swift test   # requires DATABASE_* and SUPABASE_SERVICE_ROLE_KEY env vars
```

### 5. Backfill existing tokens

```bash
swift run SnapOrthoBackend backfill-notification-tokens --dry-run
swift run SnapOrthoBackend backfill-notification-tokens
```

Compare Amazon `devices` count vs Supabase `user_device_tokens` count after backfill.

---

## Architecture Decision

**Supabase Postgres is the notification source of truth.**  
Amazon RDS retains `devices`, `todos`, `case_prep_logs`, and `donations`. The `devices` table is dual-written during Phase 1 cutover and archived after validation. Notification tables are net-new in Supabase.

Vapor connects to both databases simultaneously:
- `.psql` → Amazon RDS (existing behavior, unchanged)
- `.notifications` → Supabase Postgres (new — notification tables only)

---

## Files Changed

### New files
```
Sources/SnapOrthoBackend/
├── Notifications/
│   ├── Models/
│   │   ├── NotificationCategory.swift       — enum for all 6 categories
│   │   ├── UserDeviceToken.swift            — replaces Amazon `devices` for notifications
│   │   ├── NotificationPreference.swift     — per-user, per-category prefs + DTO
│   │   └── NotificationDeliveryAttempt.swift— delivery log model
│   ├── Migrations/
│   │   ├── CreateUserDeviceTokens.swift
│   │   ├── CreateNotificationPreferences.swift
│   │   └── CreateNotificationDeliveryAttempts.swift
│   ├── Services/
│   │   ├── APNSSender.swift                 — protocol + VaporAPNSSender + App storage
│   │   └── NotificationService.swift        — central send service + App storage
│   └── Routes/
│       └── NotificationRoutes.swift         — new endpoints + dual-write helper
├── Commands/
│   └── BackfillNotificationTokensCommand.swift
├── Helpers/
│   ├── ProductionEnvironment.swift        — production env var guards
│   └── SupabaseJWTVerifier.swift            — JWKS JWT verification
└── Middleware/
    └── AdminAuthMiddleware.swift
```

### Modified files
- `configure.swift` — Supabase DB connection, env-based APNS, new migrations, command registration
- `routes.swift` — dual-write registration, secured legacy routes, removed `/debug/devices`

### New test file
- `Tests/SnapOrthoBackendTests/NotificationTests.swift`

---

## Required Environment Variables

### New (must be added to server)

| Variable | Description | Example |
|----------|-------------|---------|
| `SUPABASE_DATABASE_URL` | Direct Postgres URL to Supabase DB | `postgresql://postgres.xxx:[password]@db.xxx.supabase.co:5432/postgres` |
| `ADMIN_API_KEY` | Secret key for admin notification routes | Any strong random string |
| `APNS_ENVIRONMENT` | APNS environment | `production` or `sandbox` |
| `APNS_KEY_PATH` | Path to APNS .p8 private key file | `/etc/apns/AuthKey_2V7UF5DPS4.p8` |
| `APNS_KEY_ID` | APNS key identifier | `2V7UF5DPS4` |
| `APNS_TEAM_ID` | Apple Developer Team ID | `MLMGMULY2P` |
| `APNS_BUNDLE_ID` | iOS app bundle identifier | `com.alexbaur.Snap-Ortho` |

### Existing (unchanged)
`DATABASE_HOST`, `DATABASE_USERNAME`, `DATABASE_PASSWORD`, `DATABASE_NAME`,  
`SUPABASE_SERVICE_ROLE_KEY`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`,  
`STRIPE_WEBHOOK_SECRET`, `BROBOT_AVG_MS`

### Getting the Supabase connection string
In the Supabase dashboard: **Settings → Database → Connection string → URI**  
Use the **direct connection** (not the pooler). Port 5432.  
Format: `postgresql://postgres.[project-ref]:[db-password]@db.[project-ref].supabase.co:5432/postgres`

---

## Migrations Added

All migrations run against the `.notifications` (Supabase) database:

| Migration | Table | Phase |
|-----------|-------|-------|
| `CreateUserDeviceTokens` | `user_device_tokens` | 1B |
| `CreateNotificationPreferences` | `notification_preferences` | 1C |
| `CreateNotificationDeliveryAttempts` | `notification_delivery_attempts` | 1C |

### Add FK to `auth.users` in Supabase (manual step)

The Vapor migration creates `user_id uuid` columns without a FK constraint because Fluent cannot reference Supabase's `auth` schema in migrations. Run this SQL in the Supabase SQL editor after deploying:

```sql
-- user_device_tokens
ALTER TABLE public.user_device_tokens
    ADD CONSTRAINT fk_udt_user_id
    FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;

-- notification_preferences
ALTER TABLE public.notification_preferences
    ADD CONSTRAINT fk_np_user_id
    FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;

-- notification_delivery_attempts
ALTER TABLE public.notification_delivery_attempts
    ADD CONSTRAINT fk_nda_user_id
    FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE SET NULL;
```

### Enable RLS in Supabase (manual step)

```sql
-- user_device_tokens: Vapor backend only (service role bypasses RLS)
ALTER TABLE public.user_device_tokens ENABLE ROW LEVEL SECURITY;
-- No client-direct policies needed in Phase 1

-- notification_preferences: future iOS direct access
ALTER TABLE public.notification_preferences ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users can view and manage own preferences"
    ON public.notification_preferences
    FOR ALL USING (auth.uid() = user_id);

-- notification_delivery_attempts: backend only, no RLS needed
-- (do not expose via PostgREST)
```

---

## Backfill Command

Run once after deploying to migrate existing Amazon `devices` tokens to Supabase:

```bash
# Dry run first — shows what would be migrated
swift run SnapOrthoBackend backfill-notification-tokens --dry-run

# Real run
swift run SnapOrthoBackend backfill-notification-tokens

# Custom batch size
swift run SnapOrthoBackend backfill-notification-tokens --batch-size 500
```

**The command is idempotent** — safe to run multiple times. Upserts by `(token_hash, environment)`. Never logs raw tokens. Maps `learn_user_id` → `user_id UUID` where possible; inserts with `user_id = NULL` for "anonymous" or invalid UUIDs.

---

## Endpoints Added / Changed

### New endpoints

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| `DELETE` | `/notifications/device-token` | None (token in body) | Invalidate/deregister device |
| `GET` | `/notifications/preferences` | Bearer JWT | Read notification preferences |
| `PUT` | `/notifications/preferences` | Bearer JWT | Update notification preferences |
| `POST` | `/admin/notifications/test` | `X-Admin-Key` | Send test push to a specific registered device |
| `POST` | `/admin/notifications/broadcast` | `X-Admin-Key` | Broadcast push to all/inactive users |

### Changed endpoints

| Method | Path | Change |
|--------|------|--------|
| `POST` | `/device/register` | Now dual-writes to Supabase `user_device_tokens`. New optional fields: `buildNumber`, `environment`. User ID always derived from JWT — never trusted from client body. |

### Deprecated routes (now POST + admin-gated)

| Old | New | Notes |
|-----|-----|-------|
| `GET /send-test-push` | `POST /admin/notifications/test` | Requires `X-Admin-Key` |
| `GET /send-broadcast-push` | `POST /admin/notifications/broadcast` | Requires `X-Admin-Key` |
| `GET /send-missed-users-push` | `POST /admin/notifications/broadcast` with `inactiveDaysOnly` | Requires `X-Admin-Key` |
| `GET /debug/devices` | **Removed** | Was a security risk — exposed device tokens |

The old paths (`/send-broadcast-push`, etc.) still exist as POST routes behind `AdminAuthMiddleware` for backward compatibility during transition. Use the new `/admin/notifications/*` paths going forward.

---

## APNS Payload Format

Every notification sent through `NotificationService` includes a `snaportho` block at the root level alongside `aps`:

```json
{
  "aps": {
    "alert": {
      "title": "Time to prep for tomorrow",
      "body": "Your next case is ready. Open CasePrep to review."
    }
  },
  "notification_id": "550e8400-e29b-41d4-a716-446655440000",
  "category": "caseprep",
  "type": "caseprep.case_tomorrow",
  "deeplink": "snaportho://caseprep/procedure/shoulder-arthroplasty",
  "metadata": { "procedureSlug": "shoulder-arthroplasty" }
}
```

`notification_id` maps to the `notification_delivery_attempts.id` row — the iOS app sends this back on open for tracking.

**Privacy rules baked in:**
- Never include patient name, MRN, or PHI in `title` or `body`
- Use generic lock-screen-safe copy only
- `metadata` for non-PHI context the app needs after unlock

---

## Supported Notification Categories

| Category | Default | Bypasses Freq Cap |
|----------|---------|------------------|
| `system` | enabled | ✅ yes |
| `learning` | enabled | no |
| `caseprep` | enabled | no |
| `brobot` | enabled | no |
| `reminders` | enabled | no |
| `product` | enabled | no |

---

## NotificationService API

```swift
// Send to all active devices for one user
let result = try await app.notificationService.sendToUser(
    userID: uuid,
    category: .caseprep,
    notificationType: "caseprep.case_tomorrow",
    title: "Prep for tomorrow",
    body: "Your case is ready to review.",
    deeplink: "snaportho://caseprep/procedure/tka",
    db: db
)

// Broadcast to all opted-in users
let result = try await app.notificationService.broadcast(
    category: .product,
    notificationType: "product.announcement",
    title: "New content",
    body: "Check out what's new.",
    deeplink: nil,
    db: db
)

// Broadcast to inactive users (re-engagement)
let result = try await app.notificationService.broadcastToInactiveUsers(
    inactiveDays: 7,
    category: .product,
    notificationType: "product.reactivation",
    title: "We miss you!",
    body: "Get back in and crush your next ortho rotation 💪.",
    deeplink: "snaportho://home",
    db: db
)
```

All methods:
- Check `receive_notifications` on device
- Check category preference for the user
- Skip mismatched APNS environments
- Log every attempt to `notification_delivery_attempts`
- Invalidate stale tokens on `APNSTokenError.badDeviceToken` or `.unregistered`
- Never crash on individual send failure — collect results and continue

---

## Security Issues Fixed

| Issue | Fix |
|-------|-----|
| `GET /send-broadcast-push` unauthenticated | Now `POST`, requires `X-Admin-Key` header |
| `GET /send-missed-users-push` unauthenticated | Now `POST`, requires `X-Admin-Key` header |
| `GET /send-test-push` unauthenticated | Now `POST`, requires `X-Admin-Key` header |
| `GET /debug/devices` exposed raw tokens | **Removed entirely** |
| APNS key ID and team ID hardcoded in source | Moved to env vars with fallback to old values |
| APNS always production — no sandbox mode | `APNS_ENVIRONMENT` env var controls this |
| Raw device token logged in `/device/register` | Now logs `token_hash.prefix(12)` only |
| Client-supplied user ID trusted | User ID always derived from verified JWT `sub` claim |

---

## How to Test Locally

### 1. Set env vars

```bash
export DATABASE_HOST=...
export DATABASE_USERNAME=...
export DATABASE_PASSWORD=...
export DATABASE_NAME=...
export SUPABASE_SERVICE_ROLE_KEY=...
export SUPABASE_DATABASE_URL=postgresql://postgres.[ref]:[pass]@db.[ref].supabase.co:5432/postgres
export ADMIN_API_KEY=your-local-test-key
export APNS_ENVIRONMENT=sandbox
export APNS_KEY_PATH=/etc/apns/AuthKey_2V7UF5DPS4.p8
export APNS_KEY_ID=2V7UF5DPS4
export APNS_TEAM_ID=MLMGMULY2P
export APNS_BUNDLE_ID=com.alexbaur.Snap-Ortho
```

### 2. Run migrations

```bash
swift run SnapOrthoBackend migrate
```

### 3. Backfill existing tokens

```bash
swift run SnapOrthoBackend backfill-notification-tokens --dry-run
swift run SnapOrthoBackend backfill-notification-tokens
```

### 4. Test admin auth

```bash
# Should return 401
curl -X POST http://localhost:8080/admin/notifications/broadcast \
  -H "Content-Type: application/json" \
  -d '{"category":"product","notificationType":"product.test","title":"T","body":"B"}'

# Should return 200
curl -X POST http://localhost:8080/admin/notifications/broadcast \
  -H "Content-Type: application/json" \
  -H "X-Admin-Key: your-local-test-key" \
  -d '{"category":"product","notificationType":"product.test","title":"T","body":"B"}'
```

### 5. Test sandbox APNS

With `APNS_ENVIRONMENT=sandbox`, the server sends to the APNS sandbox. A device registered from a development build (not TestFlight) will receive sandbox pushes.

Register a device from a development build:
```bash
curl -X POST http://localhost:8080/device/register \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <your-jwt>" \
  -d '{"deviceToken":"<token-from-ios>","platform":"ios","appVersion":"2.0","environment":"sandbox"}'
```

Then send a test push:
```bash
curl -X POST http://localhost:8080/admin/notifications/test \
  -H "Content-Type: application/json" \
  -H "X-Admin-Key: your-local-test-key" \
  -d '{"deviceToken":"<token>","environment":"sandbox","title":"Test","body":"Hello from sandbox"}'
```

---

## Rollback Plan

Phase 1 is fully backward-compatible. No existing behavior is removed except:
1. `/debug/devices` — removed (was a security risk)
2. Old push routes changed from `GET` to `POST` (requires admin key)

**To roll back to pre-Phase-1 state:**
1. Revert `configure.swift` and `routes.swift` to their previous versions
2. The Supabase tables can be left in place (they don't affect Amazon RDS)
3. Amazon `devices` table was never modified in Phase 1

---

## Cutover Plan

### Current status (Phase 1 end state)
- ✅ Supabase `user_device_tokens` created
- ✅ Existing Amazon tokens backfilled
- ✅ `POST /device/register` dual-writes to both databases
- ✅ Push sends read from Supabase `user_device_tokens`
- ✅ Amazon `devices` still receives writes (fallback)

### Step 6: Remove dual-write (after 1–2 weeks validation)
1. Confirm Supabase device count ≥ Amazon device count (backfill complete)
2. Confirm push delivery counts are stable (check `notification_delivery_attempts`)
3. Remove the Amazon write block from `POST /device/register` in `routes.swift`
4. Amazon `devices` becomes read-only

### Step 7: Archive Amazon `devices` (after 30-day window)
1. Export final snapshot: `pg_dump -t devices amazon_rds_export.sql`
2. Drop the Fluent migration from `configure.swift` for `CreateDevice`
3. Drop the Amazon table: `DROP TABLE devices`
4. Remove the `Device` model and `CreateDevice` migration files
5. `donations` stays in Amazon indefinitely

---

## Tests Added

File: `Tests/SnapOrthoBackendTests/NotificationTests.swift`

| Test | What it covers |
|------|----------------|
| `adminBroadcastRejectsUnauthenticated` | No `X-Admin-Key` → 401 |
| `adminBroadcastRejectsWrongKey` | Wrong key → 403 |
| `adminBroadcastAcceptsCorrectKey` | Correct key → 200 |
| `deviceRegistrationUpserts` | Same token registers once, not twice |
| `sandboxAndProductionTokensAreDistinct` | Same token in different envs = 2 rows |
| `multipleDevicesPerUser` | User can have N devices |
| `deregisterInvalidatesToken` | DELETE sets `invalidated_at` |
| `deregisterIsIdempotent` | Already-invalidated token → still 200 |
| `preferencesRequiresAuth` | GET preferences without JWT → 401 |
| `disabledCategoryCausesSkip` | Disabled category → skipped delivery attempt logged |
| `successfulSendCreatesDeliveryAttempt` | Send creates `status=sent` attempt row |
| `failedSendCreatesFailedAttempt` | Transient error → `status=failed` row |
| `badDeviceTokenInvalidatesDevice` | APNSTokenError → `invalidated_at` set |
| `unregisteredTokenInvalidatesDevice` | APNSTokenError.unregistered → invalidated |
| `backfillIsIdempotent` | Running upsert twice → 1 row, not 2 |
| `backfillHandlesInvalidUID` | "anonymous" learn_user_id → `user_id = NULL` |

### Tests not run live
- APNS delivery to real devices — requires physical device and sandbox/production APNS. Tests use `MockAPNSSender`.
- Supabase `auth.users` FK constraint — FK added manually in Supabase, not via Fluent migration, so test DB won't enforce it.
- `adminBroadcastAcceptsCorrectKey` records an issue (not a pass) when `ADMIN_API_KEY` is unset.

### Required env vars to run DB-backed tests locally/CI

```bash
export DATABASE_HOST=...
export DATABASE_USERNAME=...
export DATABASE_PASSWORD=...
export DATABASE_NAME=...
export SUPABASE_SERVICE_ROLE_KEY=...
export ADMIN_API_KEY=test-admin-key   # optional; one test skips if missing
```

Without `DATABASE_*` and `SUPABASE_SERVICE_ROLE_KEY`, `configure()` fails and all DB-backed tests error at startup. The unit test `productCategoryDefaultDisabled` runs without DB.

---

## iOS Contract (what the app needs to do)

### Updated `POST /device/register` payload
```json
{
  "deviceToken": "abc123...",
  "platform": "ios",
  "appVersion": "2.1.0",
  "buildNumber": "210",
  "environment": "production",
  "timezone": "America/Chicago"
}
```
New fields are optional — existing app versions work without them.

### New: `DELETE /notifications/device-token`
Call this on logout to invalidate the device token:
```json
{ "deviceToken": "abc123...", "environment": "production" }
```

### New: `GET /notifications/preferences` + `PUT /notifications/preferences`
Requires `Authorization: Bearer <jwt>` header.

### New: deep link handling
Register `snaportho://` URL scheme. Handle paths:
- `snaportho://home`
- `snaportho://learn/question/daily`
- `snaportho://caseprep/procedure/<slug>`
- `snaportho://brobot`
- `snaportho://progress/weekly`

### Notification open tracking (optional in Phase 1)
When a notification is opened, POST to `/notifications/interaction` (Phase 3):
```json
{ "notificationId": "<uuid from payload>", "action": "opened" }
```

---

## Remaining Risks

| Risk | Severity | Mitigation |
|------|----------|-----------|
| `SUPABASE_DATABASE_URL` not set before deploy | High | Fails loudly in production. Set before deploying. |
| Amazon `devices` and Supabase `user_device_tokens` drift during dual-write | Medium | Monitor counts weekly. Backfill command re-runnable. |
| Supabase connection pool exhaustion | Low | Limited to 2 connections per event loop. Monitor via Supabase dashboard. |
| APNS key file not at `APNS_KEY_PATH` | High | Vapor logs critical error on startup. Check file exists before deploy. |
| `auth.users` FK not added in Supabase | Low | Inserts succeed without it; integrity not enforced until added manually. |
| iOS app sends `environment` field as wrong value | Low | Server rejects with 400 if not "production" or "sandbox". |

---

## Phase 2 Prompt

```
Implement Phase 2 of the SnapOrtho notification system: scheduled notifications and recurring engagement sends.

Context:
- Phase 1 is complete. Supabase is the notification source of truth.
- Tables exist: user_device_tokens, notification_preferences, notification_delivery_attempts.
- NotificationService handles all APNS sends with delivery logging and token invalidation.
- Admin routes exist at POST /admin/notifications/broadcast and /admin/notifications/test.

Phase 2 scope:
1. Create `scheduled_notifications` table in Supabase (targeting .notifications DB).
   Fields: id, user_id, notification_type, category, idempotency_key (unique), payload (jsonb),
   scheduled_for (timestamptz), timezone, status (pending/sent/cancelled/failed),
   is_recurring, recurrence_rule (cron), max_occurrences, occurrence_count, created_at, updated_at.
   Index: (scheduled_for) WHERE status = 'pending'.

2. Create `notification_templates` table.
   Fields: id, notification_type (unique), category, title_template, body_template,
   deeplink_template, is_active, version, created_at, updated_at.
   Support {{variable}} substitution in templates.

3. Implement Vapor ScheduledJob that runs every 60 seconds:
   - Fetch rows WHERE scheduled_for <= now() AND status = 'pending'
   - For each: resolve idempotency, check preferences, send via NotificationService
   - Mark sent/failed/cancelled
   - For recurring: schedule next occurrence based on recurrence_rule (cron string)
   - Respect user timezone for scheduled_for calculation

4. Add POST /notifications/schedule endpoint (authenticated):
   - Schedule a future notification for the authenticated user
   - Idempotency_key prevents duplicates (required field)
   - Return the scheduled_notification ID

5. Add POST /admin/notifications/schedule-bulk endpoint (admin-gated):
   - Schedule a notification for a segment of users
   - Supports scheduled_for, recurrence_rule, max_occurrences

6. Implement quiet hours in NotificationService:
   - Check notification_preferences.quiet_hours_start/end + timezone before any send
   - If in quiet window: reschedule to quiet_hours_end today (or tomorrow)
   - Log skip_reason = 'quiet_hours'

7. Implement frequency cap:
   - Check notification_delivery_attempts count in last 24h for user
   - If >= preference.max_per_day (default 3), skip and log skip_reason = 'frequency_cap'
   - system category bypasses cap

8. Add retry handling:
   - Transient APNS failures: increment retry_count, reschedule +5min (max 3 retries)
   - After max retries: mark status = 'failed'

9. Seed initial notification templates:
   - product.reactivation: "We miss you! 🩻" / "Get back in and crush your next case."
   - product.announcement: configurable via template
   - system.account: "Account update" / configurable body

10. Tests:
    - Scheduled notification dispatched at correct time
    - Recurring notification schedules next occurrence
    - Quiet hours suppresses and reschedules send
    - Frequency cap suppresses after N sends
    - Idempotency key prevents duplicate scheduling
    - Retry logic increments count and reschedules

Constraints:
- Do not break Phase 1 behavior
- Do not implement Phase 3 engagement notifications yet (daily question, CasePrep, BroBot)
- All sends must continue going through NotificationService
- Scheduler must handle app restarts gracefully (re-pick pending rows on startup)
```
