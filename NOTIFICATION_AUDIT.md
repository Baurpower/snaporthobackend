# SnapOrtho Backend — Notification System Audit & Architecture Proposal

**Date:** 2026-06-22  
**Author:** Claude Code (AI audit)  
**Scope:** Full notification system audit of the Vapor 4 backend at `SnapOrthoBackend/`

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Storage Architecture Reassessment](#storage-architecture-reassessment)
3. [Current Architecture Map](#current-architecture-map)
4. [Current Notification Flow](#current-notification-flow)
5. [Database & Schema Findings](#database--schema-findings)
6. [API Endpoint Findings](#api-endpoint-findings)
7. [APNS / Configuration Findings](#apns--configuration-findings)
8. [Major Risks & Bugs](#major-risks--bugs)
9. [Product Opportunities](#product-opportunities)
10. [Proposed Notification System Architecture](#proposed-notification-system-architecture)
11. [Proposed Database Migrations](#proposed-database-migrations)
11. [Proposed API Contracts](#proposed-api-contracts)
12. [Proposed APNS Payload Format](#proposed-apns-payload-format)
13. [Proposed Queue / Scheduler Design](#proposed-queue--scheduler-design)
14. [Proposed Analytics Model](#proposed-analytics-model)
15. [Phased Implementation Roadmap](#phased-implementation-roadmap)
16. [Go / No-Go Recommendation](#go--no-go-recommendation)

---

## Executive Summary

> **Storage decision added 2026-06-22:** Notification tables will be built in Supabase Postgres, not Amazon RDS. See [Storage Architecture Reassessment](#storage-architecture-reassessment) for full rationale and migration plan. Phase 1 implementation plan is updated accordingly.

The current notification system is a manual, brittle, barely-functional skeleton. There is one device token table, three hardcoded push routes triggered by HTTP GET requests, no scheduler, no queue, no delivery logging, no APNS error handling, no user preference management, and no deep linking. 

This is not a notification system — it is a prototype. It cannot support any meaningful engagement loop.

**The risk is high:** Stale tokens accumulate, failed sends go undetected, APNS credentials are hardcoded, and users have no way to opt out. At scale this will cause silent failures, wasted sends, and potential APNS account termination.

**The opportunity is enormous:** SnapOrtho has natural, high-frequency notification hooks — daily learning questions, CasePrep prep reminders, BroBot follow-up, streak nudges — none of which exist today. A well-built notification system can dramatically increase DAU, learning outcomes, and premium conversions.

**Recommendation:** Do not implement Phase 3+ engagement notifications yet. Fix the foundation first (Phase 1), then layer in scheduling (Phase 2), then engagement content (Phase 3+). The phased roadmap below is achievable without breaking existing app contracts.

---

---

## Storage Architecture Reassessment

### Current Two-Database Reality

The Vapor backend currently runs against **two separate data stores** with clearly separated roles:

| System | Role | How Vapor connects |
|--------|------|--------------------|
| **Amazon RDS Postgres** | All application tables (`devices`, `todos`, `case_prep_logs`, `donations`) | FluentPostgresDriver via `DATABASE_HOST` env vars |
| **Supabase** | User identity / auth only | REST API calls to `/auth/v1/verify` and `/auth/v1/user` |

Supabase is the canonical user identity system. The Supabase UUID from the JWT `sub` claim is what Vapor stores in `devices.learn_user_id`. These UUIDs match `auth.users.id` exactly — there is no ID translation layer.

The user's broader Supabase project (`geznczcokbgybsseipjg`) already holds all business-critical data: user profiles, BroBot sessions, CasePrep logs, entitlements, and analytics. The Amazon RDS instance holds only the `devices` table that matters for notifications, plus `todos` (feature-incomplete), `case_prep_logs` (superseded by Supabase), and `donations`.

### Why Notification Tables Should Live in Supabase

**1. User foreign keys are free.**  
Supabase `auth.users.id` is the user identifier everywhere in the app. Notification tables that live in Supabase can carry a real `user_id UUID REFERENCES auth.users(id)` foreign key, giving referential integrity with zero extra work. In Amazon RDS, `learn_user_id` is a bare string with no constraint.

**2. Row Level Security without extra infrastructure.**  
Supabase RLS policies can restrict `notification_preferences` reads to the owning user. Future client-direct queries (e.g., the iOS app reading its own preferences via Supabase SDK) become possible without routing through Vapor. This is a significant long-term simplification.

**3. Realtime / Supabase Functions as a future unlock.**  
Supabase Realtime and Edge Functions can subscribe to `scheduled_notifications` inserts. This allows serverless trigger-based notification dispatch in Phase 4+ without running a persistent Vapor scheduler.

**4. Single source of truth.**  
If BroBot sessions, CasePrep completions, and case logs live in Supabase, then the notification system can join against them directly using standard SQL — no cross-database HTTP calls required to answer "did this user finish their CasePrep yesterday?"

**5. Eliminates the Amazon RDS dependency entirely (long-term).**  
After migration, the only reason Vapor needs Amazon RDS is `todos` and `donations`. `todos` appears to be a development artifact. `donations` could move to Supabase at any time. The long-term trajectory is a Vapor backend that has **one database: Supabase Postgres**.

### Why This Is Low Risk

- Vapor already uses `FluentPostgresDriver`. Supabase Postgres is standard Postgres. Adding a second Fluent database connection pointing at Supabase requires a few lines in `configure.swift` and a `SUPABASE_DATABASE_URL` env var.
- The Supabase Postgres connection string is available in the Supabase dashboard under Settings → Database → Connection String. Supabase exposes both a direct connection and a connection pooler (PgBouncer). For Vapor's long-lived server process, **direct connection** is correct (not transaction-mode pooler).
- No data needs to move from Supabase to Amazon — notification tables are net-new. Only the existing `devices` rows need to be backfilled into Supabase.
- The existing Amazon `devices` table is kept as a read-only fallback during migration. It is not dropped until Supabase is validated in production.

### Current Amazon RDS Tables: Migration Disposition

| Table | Row count significance | Migration action |
|-------|----------------------|-----------------|
| `devices` | Active — all device tokens | **Migrate to Supabase.** Backfill existing rows. Dual-write during cutover. |
| `todos` | Appears unused (dev artifact) | Archive and drop after verification |
| `case_prep_logs` | Likely superseded by Supabase CasePrep tables | Confirm with app team; archive or migrate |
| `donations` | Active — Stripe webhook data | Keep in Amazon RDS for now, migrate separately in future sprint |

### How Vapor Connects to Supabase Postgres

Supabase exposes standard Postgres on port `5432` (direct) and `6543` (pooler, transaction mode). Vapor must use the **direct connection** because Fluent ORM uses session-level features (prepared statements, `LISTEN/NOTIFY`, `BEGIN/COMMIT`) that are incompatible with transaction-mode PgBouncer.

```swift
// configure.swift — add alongside existing Amazon RDS config
if let supabaseDBURL = Environment.get("SUPABASE_DATABASE_URL") {
    try app.databases.use(
        .postgres(url: supabaseDBURL),
        as: .supabase
    )
}
```

All notification Fluent models will specify `.supabase` as their database:

```swift
extension UserDeviceToken {
    static let schema = "user_device_tokens"
    // Models targeting Supabase use the .supabase database ID
}
```

The existing Amazon RDS models continue using the `.default` database ID unchanged. Both databases run simultaneously during the cutover window. There is no ORM migration incompatibility because they are on separate connections.

### Supabase Schema Placement

All notification tables will live in Supabase's `public` schema unless otherwise specified. They will use `auth.users.id` as the `user_id` foreign key. RLS policies will be added so the iOS app can query preferences directly via Supabase SDK if desired (Vapor is still the write path for now).

### Proposed Supabase Notification Tables (replacing Amazon RDS)

| New table | Replaces | Notes |
|-----------|---------|-------|
| `user_device_tokens` | `devices` | Renamed for clarity; adds `apns_environment`, `is_active`, proper FK to `auth.users` |
| `notification_preferences` | Nothing (new) | Per-user, per-category opt-in/out |
| `notification_events` | Nothing (new) | Delivery log |
| `notification_delivery_attempts` | Nothing (new) | APNS response tracking |
| `scheduled_notifications` | Nothing (new) | Phase 2 queue |
| `notification_interactions` | Nothing (new) | Open/dismiss/deep-link tracking |
| `notification_templates` | Nothing (new) | Phase 2 copy management |

### Safe Migration Steps (detailed in Phase 1 below)

1. **Add `SUPABASE_DATABASE_URL` env var to Vapor server.** No code change yet.
2. **Add Supabase as second Fluent database in `configure.swift`.** Existing Amazon queries unaffected.
3. **Create `user_device_tokens` table in Supabase** via Supabase SQL editor (migration SQL in section below).
4. **Backfill** existing `devices` rows into `user_device_tokens` via one-time script.
5. **Dual-write**: `POST /device/register` writes to both Amazon `devices` and Supabase `user_device_tokens`.
6. **Cut reads**: Push send routes read from Supabase `user_device_tokens`; Amazon is no longer queried for sends.
7. **Monitor** for 1–2 weeks. Confirm delivery counts match. Confirm no regressions.
8. **Remove dual-write.** Amazon `devices` becomes read-only.
9. **Archive Amazon `devices`** after 30-day validation window. Keep `donations` in Amazon.

---

## Current Architecture Map

```
┌─────────────────────────────────────────────────────────────────┐
│                     iOS App                                       │
│                                                                   │
│  Device Token Registration ──────────────────────────────────►  │
│  (POST /device/register)                                         │
└──────────────────────────────────┬──────────────────────────────┘
                                   │
                                   ▼
┌─────────────────────────────────────────────────────────────────┐
│                   Vapor 4 Backend                                 │
│                                                                   │
│   routes.swift                                                    │
│   ├── POST /device/register    → Upsert device record            │
│   ├── GET  /send-test-push     → Hardcoded token, manual         │
│   ├── GET  /send-broadcast-push→ All opted-in users, manual      │
│   ├── GET  /send-missed-users-push → Inactive 7d, manual        │
│   └── GET  /debug/devices      → List all devices                │
│                                                                   │
│   configure.swift                                                 │
│   └── VaporAPNS configured with JWT auth (production only)       │
└──────────────────────────────────┬──────────────────────────────┘
                                   │ VaporAPNS (JWT)
                                   ▼
┌─────────────────────────────────────────────────────────────────┐
│                   Apple APNS (Production)                         │
│                                                                   │
│   ← No feedback loop back to server                              │
│   ← No failure handling                                          │
│   ← No token invalidation cleanup                                │
└─────────────────────────────────────────────────────────────────┘

Database:
┌──────────────┐
│   devices    │
│──────────────│
│ id (UUID)    │
│ device_token │ ← unique constraint
│ learn_user_id│ ← "anonymous" for unauthed
│ platform     │
│ app_version  │
│ last_seen    │
│ language     │
│ timezone     │
│ receive_notif│ ← single boolean, all-or-nothing
│ last_notified│ ← set but never read
│ created_at   │
│ updated_at   │
└──────────────┘
```

---

## Current Notification Flow

```
Admin opens browser →
  GET /send-broadcast-push
    → SELECT * FROM devices WHERE receive_notifications = true
    → For each device:
        APNSAlertNotification(
          title: "New Learn Sketch!",
          body:  "Out Now - Open fractures 🏍️"   ← HARDCODED
        )
        → sendAlertNotification(notification, deviceToken: token)
        → Error? → append to failedTokens []
        → Success? → increment successCount
    → Return JSON { success: N, failed: M, failedTokens: [...] }

No retry. No logging. No delivery record. No deep link. 
Failed tokens are returned in the response but never cleaned up.
```

---

## Database & Schema Findings

### Existing: `devices` table

| Column | Type | Notes |
|--------|------|-------|
| `id` | UUID | Primary key |
| `device_token` | String | UNIQUE — correct |
| `learn_user_id` | String | "anonymous" for unauthed users |
| `platform` | String | e.g. "iOS" |
| `app_version` | String | e.g. "1.2.3" |
| `last_seen` | Date | Updated on registration only |
| `language` | String? | Optional |
| `timezone` | String? | Optional — stored but never used for scheduling |
| `receive_notifications` | Bool | Default true — no per-category preferences |
| `last_notified` | Date? | Set nowhere in current code |
| `created_at` | Timestamp | Auto |
| `updated_at` | Timestamp | Auto |

**Gaps:**
- One token per row, but there is no explicit user → many device relationship enforced
- `learn_user_id` is a String (Supabase UID or "anonymous") — not a foreign key
- No APNS environment flag (sandbox vs production) — dangerous
- `last_notified` exists but is never written
- Single `receive_notifications` boolean — no category-level control
- No table for what was sent, when, why, or whether it was opened

### Missing tables (see Proposed Migrations):
- `notification_preferences` — per-user, per-category opt-in/out
- `notification_events` — log of every notification dispatched
- `notification_templates` — versioned copy/payload templates
- `scheduled_notifications` — queue for future/recurring sends
- `notification_delivery_attempts` — APNS result tracking
- `notification_interactions` — open/dismiss/deep-link events

---

## API Endpoint Findings

### Notification-related endpoints

| Method | Path | Auth | Issues |
|--------|------|------|--------|
| `POST` | `/device/register` | Bearer (optional) | No upsert atomicity, no sandbox flag |
| `GET` | `/send-test-push` | None | Hardcoded token, GET semantics wrong |
| `GET` | `/send-broadcast-push` | None | No auth, no rate limit, GET semantics wrong |
| `GET` | `/send-missed-users-push` | None | No auth, no rate limit, GET semantics wrong |
| `GET` | `/debug/devices` | None | Exposes all device tokens — security risk |

### Missing endpoints:
- `DELETE /device/token` — logout/deregister
- `PUT /notifications/preferences` — per-category opt-in/out
- `GET /notifications/preferences` — read current settings
- `POST /notifications/interaction` — track open/dismiss
- `POST /admin/notifications/send` — authenticated admin send (replace GET routes)

---

## APNS / Configuration Findings

### Current configuration (configure.swift lines 60–76)

```swift
let apnsConfig = try APNSClientConfiguration(
    authenticationMethod: .jwt(
        privateKey: try .loadFrom(string: String(contentsOfFile: "/etc/apns/AuthKey_2V7UF5DPS4.p8")),
        keyIdentifier: "2V7UF5DPS4",
        teamIdentifier: "MLMGMULY2P"
    ),
    environment: .production
)
```

**Findings:**
- ✅ JWT auth (correct approach — no cert rotation needed)
- ✅ Production environment set
- ❌ Key file path is hardcoded — will silently crash on any server without `/etc/apns/`
- ❌ Key ID and Team ID are hardcoded in source — should be env vars
- ❌ No sandbox mode — cannot test safely without hitting production APNS
- ❌ No environment variable fallback — zero flexibility for staging
- ❌ App bundle ID `com.alexbaur.Snap-Ortho` hardcoded in route handlers — should be a constant

### APNS error handling audit

Current send pattern (routes.swift):
```swift
do {
    try await req.apns.client.sendAlertNotification(notification, deviceToken: token.deviceToken)
    successCount += 1
} catch {
    failedTokens.append(token.deviceToken)
    req.logger.error("APNS error for \(token.deviceToken): \(error)")
}
```

**Findings:**
- ❌ Errors are caught and logged but not acted on
- ❌ APNS returns a specific `BadDeviceToken` / `Unregistered` error — code does not distinguish these
- ❌ Invalid tokens are never removed from the database
- ❌ No retry for transient failures (server errors, rate limits)
- ❌ No distinction between permanent failure (delete token) vs transient (retry later)
- ❌ Sends happen synchronously inside the request handler — will block/timeout for large user bases

---

## Major Risks & Bugs

### CRITICAL

**1. No sandbox mode**
All sends go to production APNS. You cannot safely test without shipping real notifications to real users. Any mistake in a test send goes to everyone.

**2. Admin send routes have no authentication**
`GET /send-broadcast-push` and `GET /send-missed-users-push` require no auth. Anyone who knows the URL can trigger a mass push to all users. This is a serious misuse risk.

**3. `/debug/devices` exposes all device tokens**
Device tokens should be treated as sensitive credentials. This endpoint should be removed or placed behind admin auth.

**4. Synchronous sends block the Vapor event loop**
Sending to 1,000 devices one-by-one in a request handler will cause timeouts and event loop starvation. This will cause 502s and degrade the entire server.

**5. Stale tokens accumulate forever**
When users uninstall the app, APNS returns `Unregistered`. The server never sees this response (no feedback loop) and the token remains in the database. Over time the majority of tokens will be invalid, wasting sends and consuming APNS rate limits.

### HIGH

**6. Race condition in device registration**
Check-then-insert pattern for device tokens can create duplicates under concurrent requests. Should use database upsert.

**7. No user notification preference endpoint**
Users cannot opt out of notifications without contacting you. This likely violates App Store guidelines.

**8. `last_notified` never written**
The field exists to rate-limit notifications per device but is never updated, so it provides no protection.

**9. Hardcoded notification copy in route handlers**
Changing notification copy requires a backend deploy. There is no template system.

**10. No deep links**
Notifications open the app but land on whatever screen was last open. There is no way to direct users to specific content.

### MEDIUM

**11. APNS key ID in source code**
The key ID and team ID are hardcoded in `configure.swift`. Should be environment variables.

**12. Single boolean notification preference**
No way to say "send me CasePrep reminders but not broadcast announcements."

**13. No notification history**
No way to know what was sent to whom, when, or whether it was received. Cannot debug or audit.

**14. timezone stored but never used**
The `timezone` column exists but all sends happen at whatever time the admin runs the route. Users in different time zones will receive notifications at inappropriate hours.

---

## Product Opportunities

SnapOrtho has natural, high-frequency engagement hooks that don't exist in any notification today:

| Notification Type | Trigger | Frequency | Expected Impact |
|------------------|---------|-----------|-----------------|
| Daily OITE Question | Scheduled 8am user-local | Daily | High — builds habit |
| Daily Ortho Pearl | Scheduled 7am user-local | Daily | High — learning loop |
| CasePrep: Case Tomorrow | Tomorrow's case detected | Per case | Very high — direct utility |
| CasePrep: Finish Your Prep | Started but didn't finish | Per case | Very high |
| BroBot Follow-Up | 24h after BroBot session | Per session | High — re-engagement |
| Saved Topic Reminder | Topic saved, not revisited in 7d | Weekly | Medium |
| Streak Reminder | Streak about to break | Daily | High — gamification |
| Weekly Progress Summary | Sunday evening | Weekly | Medium |
| Attending Preference Alert | New preference added | Per event | High — workflow |
| Inactivity Reactivation | 7-day inactive | Once per gap | High — retention |
| Onboarding Activation | 24h after install, no activity | Once | High — conversion |
| Postop Follow-Up Task | Postop reminder set | Per task | High — clinical utility |

**Privacy note:** Notifications should never include patient names, MRNs, or procedure details in the visible body. Use generic copy ("Your case tomorrow is ready for prep") and require app unlock to see details.

---

## Proposed Notification System Architecture

### A. Notification Categories

```
NotificationCategory
├── learning           Daily question, pearls, topic reminders
├── casePrep           Pre-case prep reminders, finish-prep nudges  
├── brobot             Follow-up nudges after BroBot sessions
├── caseTracking       Case log reminders, postop tasks
├── streakProgress     Streak reminders, weekly summaries
├── product            Onboarding, reactivation, feature announcements
└── system             Account, subscription, security
```

Each category is independently toggleable by the user. New categories can be added without breaking existing preferences.

### B. Notification Types (typed enum)

```swift
enum NotificationType: String, Codable {
    // Learning
    case dailyQuestion         = "learning.daily_question"
    case dailyPearl            = "learning.daily_pearl"
    case savedTopicReminder    = "learning.saved_topic"
    case weakAreaReminder      = "learning.weak_area"
    
    // CasePrep
    case caseTomorrow          = "caseprep.case_tomorrow"
    case finishPrep            = "caseprep.finish_prep"
    case casePrepAvailable     = "caseprep.available"
    
    // BroBot
    case brobotFollowUp        = "brobot.follow_up"
    case brobotTopicContinue   = "brobot.topic_continue"
    
    // Case Tracking
    case caseLogReminder       = "casetracking.log_reminder"
    case postopTask            = "casetracking.postop_task"
    
    // Streak / Progress
    case streakReminder        = "streak.reminder"
    case weeklyProgress        = "progress.weekly_summary"
    case milestoneReached      = "progress.milestone"
    
    // Product
    case onboardingActivation  = "product.onboarding"
    case inactivityReactivation = "product.reactivation"
    case featureAnnouncement   = "product.announcement"
    
    // System
    case subscriptionExpiring  = "system.subscription"
    case accountAlert          = "system.account"
}
```

Every notification sent must have a `NotificationType`. This becomes the backbone for analytics, preferences, and templating.

### C. Centralized Notification Service

Replace all route-level send logic with a single `NotificationService`:

```swift
struct NotificationService {
    // Send one notification to one user (resolves their devices)
    func send(_ type: NotificationType, to userID: String, payload: NotificationPayload, on db: Database) async throws
    
    // Schedule a notification for future delivery
    func schedule(_ type: NotificationType, for userID: String, at: Date, payload: NotificationPayload, idempotencyKey: String, on db: Database) async throws
    
    // Send to a segment of users
    func broadcast(_ type: NotificationType, to segment: UserSegment, payload: NotificationPayload, on db: Database) async throws
    
    // Cancel a scheduled notification
    func cancel(idempotencyKey: String, on db: Database) async throws
    
    // Internal: resolve devices, check preferences, quiet hours, send, log
    private func dispatchToDevice(_ device: Device, payload: APNSPayload, eventID: UUID, on db: Database) async throws
}
```

### D. Deep Link Payload Format

Every notification includes a `deepLink` key in the APNS custom payload:

```json
{
  "aps": {
    "alert": {
      "title": "Time to prep your case",
      "body": "Your next case is scheduled for tomorrow morning."
    },
    "sound": "default",
    "badge": 1
  },
  "snaportho": {
    "notificationType": "caseprep.case_tomorrow",
    "deepLink": "snaportho://caseprep/procedure/shoulder-arthroplasty",
    "category": "casePrep",
    "eventID": "uuid-here",
    "version": 1
  }
}
```

**Deep link scheme:** `snaportho://<screen>/<identifier>`

| Screen | Deep Link |
|--------|-----------|
| BroBot chat | `snaportho://brobot` |
| BroBot with topic | `snaportho://brobot?topic=shoulder` |
| CasePrep for procedure | `snaportho://caseprep/procedure/<slug>` |
| Daily question | `snaportho://learn/question/daily` |
| OITE question ID | `snaportho://learn/question/<id>` |
| Case log | `snaportho://cases/log` |
| Attending preferences | `snaportho://settings/preferences` |
| Weekly summary | `snaportho://progress/weekly` |
| Subscription | `snaportho://subscription` |

The `eventID` ties the notification open back to the `notification_events` record for analytics.

---

## Proposed Database Migrations

> **Updated decision:** All new notification tables are created in **Supabase Postgres**, not Amazon RDS. The Amazon `devices` table is retained as a dual-write fallback during cutover and archived after validation. See [Storage Architecture Reassessment](#storage-architecture-reassessment) for rationale.

### Amazon RDS: No new tables

The Amazon RDS instance receives two minor alterations to support the dual-write transition period, then is frozen:

```sql
-- Amazon RDS only — keep existing devices table functional during cutover
ALTER TABLE devices ADD COLUMN IF NOT EXISTS apns_environment TEXT NOT NULL DEFAULT 'production';
ALTER TABLE devices ADD COLUMN IF NOT EXISTS is_active BOOLEAN NOT NULL DEFAULT true;
-- No further migrations on Amazon RDS for notification purposes
```

### Supabase Postgres: All new notification tables

The SQL in Phase 1B above is the canonical migration. Summary:

### Supabase Migration 1: `user_device_tokens` (Phase 1B)

Replaces Amazon `devices`. Adds `user_id UUID REFERENCES auth.users(id)`, `apns_environment`, `is_active`. Enforces referential integrity with Supabase auth. RLS enabled.

### Supabase Migration 2: `notification_preferences` (Phase 1C)

Full SQL in Phase 1B. Key changes from original design: `user_id UUID REFERENCES auth.users(id)` (real FK), RLS enabled so users can manage own preferences via Supabase SDK directly. `timezone` moved here from `user_device_tokens` (preference-level, not device-level).

### Supabase Migration 3: `notification_events` (Phase 1C)

Full SQL in Phase 1B. Key changes: `device_token_id UUID REFERENCES public.user_device_tokens(id)` (FK to Supabase table, not Amazon), `user_id UUID` (typed UUID not TEXT), `skip_reason` column added for analytics.

### Supabase Migration 4: `scheduled_notifications` (Phase 2)

```sql
CREATE TABLE public.scheduled_notifications (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE,
    notification_type TEXT NOT NULL,
    category TEXT NOT NULL,
    idempotency_key TEXT UNIQUE NOT NULL,
    payload JSONB NOT NULL,
    scheduled_for TIMESTAMPTZ NOT NULL,
    timezone TEXT,
    status TEXT NOT NULL DEFAULT 'pending',
    is_recurring BOOLEAN NOT NULL DEFAULT false,
    recurrence_rule TEXT,
    max_occurrences INT,
    occurrence_count INT NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX ON public.scheduled_notifications(scheduled_for) WHERE status = 'pending';
CREATE INDEX ON public.scheduled_notifications(user_id);
```

### Supabase Migration 5: `notification_interactions` (Phase 3)

```sql
CREATE TABLE public.notification_interactions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    event_id UUID REFERENCES public.notification_events(id),
    user_id UUID REFERENCES auth.users(id),
    action TEXT NOT NULL,
    deep_link TEXT,
    app_version TEXT,
    interacted_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX ON public.notification_interactions(event_id);
CREATE INDEX ON public.notification_interactions(user_id);
```

### Supabase Migration 6: `notification_templates` (Phase 2)

```sql
CREATE TABLE public.notification_templates (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    notification_type TEXT NOT NULL UNIQUE,
    category TEXT NOT NULL,
    title_template TEXT NOT NULL,
    body_template TEXT NOT NULL,
    deep_link_template TEXT,
    is_active BOOLEAN NOT NULL DEFAULT true,
    version INT NOT NULL DEFAULT 1,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
```

---

## Proposed API Contracts

### Device Registration

**`POST /device/register`** (existing — extend, don't break)

Request:
```json
{
  "deviceToken": "abc123...",
  "platform": "ios",
  "appVersion": "2.1.0",
  "apnsEnvironment": "production",    // NEW: "production" | "sandbox"
  "language": "en",
  "timezone": "America/Chicago",
  "isAuthenticated": true
}
```

Response:
```json
{ "success": true, "deviceId": "uuid" }
```

---

### Device Deregistration (NEW)

**`DELETE /device/token`**

Request:
```json
{ "deviceToken": "abc123..." }
```

Marks device as `is_active = false`. Does not hard delete (preserves analytics history).

---

### Notification Preferences (NEW)

**`GET /notifications/preferences`** — requires Bearer auth

Response:
```json
{
  "preferences": [
    { "category": "learning", "enabled": true },
    { "category": "casePrep", "enabled": true },
    { "category": "brobot", "enabled": false },
    { "category": "streakProgress", "enabled": true },
    { "category": "product", "enabled": true }
  ],
  "quietHoursStart": 22,
  "quietHoursEnd": 7,
  "timezone": "America/Chicago",
  "maxPerDay": 3
}
```

**`PUT /notifications/preferences`** — requires Bearer auth

Request: same shape as response above.

---

### Notification Interaction Tracking (NEW)

**`POST /notifications/interaction`** — requires Bearer auth

Request:
```json
{
  "eventId": "uuid",
  "action": "opened",
  "deepLink": "snaportho://caseprep/procedure/shoulder-arthroplasty",
  "appVersion": "2.1.0"
}
```

---

### Admin: Send Notification (replaces GET routes)

**`POST /admin/notifications/send`** — requires admin auth header

Request:
```json
{
  "type": "product.announcement",
  "segment": "all_active",
  "title": "New Learn Sketch!",
  "body": "Open fractures — now available.",
  "deepLink": "snaportho://learn/sketches",
  "scheduledFor": null
}
```

---

## Proposed APNS Payload Format

```json
{
  "aps": {
    "alert": {
      "title": "Time to prep for tomorrow",
      "body": "You have a case scheduled. Open CasePrep to get ready."
    },
    "sound": "default",
    "badge": 1,
    "content-available": 0,
    "interruption-level": "active",
    "thread-id": "caseprep"
  },
  "snaportho": {
    "v": 1,
    "eventId": "550e8400-e29b-41d4-a716-446655440000",
    "notificationType": "caseprep.case_tomorrow",
    "category": "casePrep",
    "deepLink": "snaportho://caseprep/procedure/shoulder-arthroplasty",
    "metadata": {
      "procedureSlug": "shoulder-arthroplasty"
    }
  }
}
```

**Rules:**
- Never include patient name, MRN, or PHI in `title` or `body`
- `deepLink` always present if there is a relevant screen
- `eventId` always present for open tracking
- `metadata` for any additional non-PHI context the app needs
- `thread-id` groups related notifications in Notification Center

**APNS Headers:**
- `apns-topic`: `com.alexbaur.Snap-Ortho` (constant, not hardcoded per route)
- `apns-push-type`: `alert`
- `apns-priority`: `10` (immediate) for time-sensitive, `5` (conserve power) for non-urgent
- `apns-expiration`: Set appropriately (e.g., CasePrep expires after the case date)

---

## Proposed Queue / Scheduler Design

### Architecture

```
┌──────────────────┐     ┌──────────────────────────┐     ┌──────────────────┐
│  Notification    │────►│  scheduled_notifications  │────►│  Vapor Scheduled │
│  Trigger         │     │  table (Postgres queue)   │     │  Job (every 60s) │
│  (route / event) │     └──────────────────────────┘     └────────┬─────────┘
└──────────────────┘                                               │
                                                                    │ For each pending row
                                                                    ▼
                                                        ┌──────────────────────┐
                                                        │  NotificationService  │
                                                        │  1. Check preferences │
                                                        │  2. Check quiet hours │
                                                        │  3. Check freq cap    │
                                                        │  4. Resolve devices   │
                                                        │  5. Send via APNS    │
                                                        │  6. Log to events    │
                                                        │  7. Update status    │
                                                        └──────────────────────┘
```

### Vapor Scheduled Job

```swift
// In configure.swift
app.scheduled.jobs.add(NotificationDispatchJob())

struct NotificationDispatchJob: AsyncScheduledJob {
    func run(context: QueueContext) async throws {
        // Fetch pending scheduled_notifications where scheduled_for <= now
        // Dispatch in batches of 100
        // Mark sent or failed
        // Handle recurring notifications (schedule next occurrence)
    }
    
    var scheduledAt: ScheduleBuilder {
        schedule.minutely()  // Run every minute
    }
}
```

### Idempotency

Every scheduled notification has an `idempotency_key` (e.g., `"caseprep.tomorrow.\(userID).\(caseDate)"`). Before inserting, check if key exists. Before sending, re-check. This prevents duplicate sends on retries or scheduler restarts.

### Retry Policy

| APNS Error | Action |
|------------|--------|
| `BadDeviceToken` | Delete device, no retry |
| `Unregistered` | Mark device inactive, no retry |
| `TooManyRequests` | Retry with exponential backoff (max 3x) |
| Network error | Retry up to 3x, then mark failed |
| `BadMessageId` | Log, no retry |

### Quiet Hours

Before any send, check `notification_preferences.quiet_hours_start/end` for the user and their `timezone`. If current local time is in quiet window, re-schedule to `quiet_hours_end` today (or tomorrow if already past).

### Frequency Cap

Before sending, count `notification_events` for this user in the last 24 hours. If >= `max_per_day`, skip (log skip reason). `system` category bypasses frequency cap.

---

## Proposed Analytics Model

### Events to track

| Event | When | Data |
|-------|------|------|
| `notification.scheduled` | Row inserted in `scheduled_notifications` | type, userID, scheduledFor |
| `notification.sent` | APNS call made | type, userID, deviceID, eventID |
| `notification.apns_accepted` | APNS 200 response | eventID, apnsID |
| `notification.apns_failed` | APNS error | eventID, errorCode, reason |
| `notification.token_invalidated` | BadDeviceToken / Unregistered | deviceID |
| `notification.opened` | POST /notifications/interaction with action=opened | eventID, deepLink |
| `notification.deep_link_completed` | POST /notifications/interaction with action=deep_link_completed | eventID, deepLink |
| `notification.skipped_quiet_hours` | Send suppressed | type, userID |
| `notification.skipped_frequency_cap` | Send suppressed | type, userID |
| `notification.skipped_preference_off` | Send suppressed | type, userID, category |

All events stored in `notification_events` + structured Vapor logger output. Future: forward to analytics backend (PostHog, Amplitude, etc.) via a thin event emitter.

### Key metrics to monitor

- **Delivery rate:** `apns_accepted / sent`
- **Open rate:** `opened / apns_accepted` per type
- **Deep link completion rate:** `deep_link_completed / opened`
- **Opt-out rate:** preference changes per category over time
- **Token invalidity rate:** `token_invalidated / sent` — rising rate signals install churn
- **Quiet hours hit rate:** per user, per time of day

---

## Phased Implementation Roadmap

### Phase 1 — Notification Foundation (2–3 weeks)
*Fix what's broken. Migrate notification storage to Supabase. Build the correct foundation.*

Phase 1 is split into three sequential sub-phases to ensure safe migration with no downtime.

---

#### Phase 1A — Critical Security Hotfixes (Day 1–2, ship immediately)
*These are high-severity issues that can be fixed with zero app changes and zero migration risk.*

**Backend tasks:**
- [ ] Add `ADMIN_SECRET` env var; require `X-Admin-Secret` header on `/send-broadcast-push`, `/send-missed-users-push`, `/send-test-push` — block unauthenticated requests with 401
- [ ] Remove `/debug/devices` endpoint or gate it behind admin auth
- [ ] Move APNS private key path, key ID, team ID, and app bundle ID to env vars (`APNS_KEY_PATH`, `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_BUNDLE_ID`)
- [ ] Add `APNS_ENVIRONMENT` env var (`production` | `sandbox`); wire into `APNSClientConfiguration`
- [ ] Change admin send routes from `GET` to `POST`

**Definition of done:** Admin routes require auth. APNS credentials are not in source. Sandbox mode is available for safe testing.

---

#### Phase 1B — Supabase Storage Migration (Week 1–2)
*Create new notification tables in Supabase Postgres and migrate device tokens off Amazon RDS.*

**Step 1: Supabase schema (run in Supabase SQL editor)**

```sql
-- user_device_tokens: replaces Amazon RDS `devices` table
CREATE TABLE public.user_device_tokens (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE,
    -- NULL for anonymous/unauthenticated devices (allowed)
    anonymous_id TEXT,                  -- "anonymous" or internal ID for pre-auth devices
    device_token TEXT NOT NULL UNIQUE,
    platform TEXT NOT NULL DEFAULT 'ios',
    app_version TEXT NOT NULL,
    apns_environment TEXT NOT NULL DEFAULT 'production', -- 'production' | 'sandbox'
    is_active BOOLEAN NOT NULL DEFAULT true,
    last_seen TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    language TEXT,
    timezone TEXT,                      -- IANA timezone string, e.g. "America/Chicago"
    last_notified TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX ON public.user_device_tokens(user_id) WHERE user_id IS NOT NULL;
CREATE INDEX ON public.user_device_tokens(is_active) WHERE is_active = true;

-- RLS: users can only read their own device tokens; Vapor service role bypasses RLS
ALTER TABLE public.user_device_tokens ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users can view own tokens" ON public.user_device_tokens
    FOR SELECT USING (auth.uid() = user_id);
-- Vapor writes via service role key (bypasses RLS) — no insert policy needed for now

-- notification_preferences: per-user, per-category opt-in/out
CREATE TABLE public.notification_preferences (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    category TEXT NOT NULL,
    enabled BOOLEAN NOT NULL DEFAULT true,
    quiet_hours_start INT CHECK (quiet_hours_start BETWEEN 0 AND 23),
    quiet_hours_end INT CHECK (quiet_hours_end BETWEEN 0 AND 23),
    max_per_day INT DEFAULT 3,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(user_id, category)
);
CREATE INDEX ON public.notification_preferences(user_id);

ALTER TABLE public.notification_preferences ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users can manage own preferences" ON public.notification_preferences
    FOR ALL USING (auth.uid() = user_id);

-- notification_events: delivery log for every send attempt
CREATE TABLE public.notification_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES auth.users(id),
    anonymous_id TEXT,
    device_token_id UUID REFERENCES public.user_device_tokens(id),
    notification_type TEXT NOT NULL,    -- e.g. "caseprep.case_tomorrow"
    category TEXT NOT NULL,             -- e.g. "casePrep"
    idempotency_key TEXT UNIQUE,
    title TEXT NOT NULL,
    body TEXT NOT NULL,
    deep_link TEXT,
    custom_data JSONB,
    scheduled_for TIMESTAMPTZ,
    sent_at TIMESTAMPTZ,
    apns_status TEXT NOT NULL DEFAULT 'pending',  -- pending | sent | failed | invalid_token | skipped
    apns_id TEXT,                       -- APNS response apns-id header
    failure_reason TEXT,
    retry_count INT NOT NULL DEFAULT 0,
    skip_reason TEXT,                   -- quiet_hours | frequency_cap | preference_off | inactive_token
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX ON public.notification_events(user_id);
CREATE INDEX ON public.notification_events(notification_type);
CREATE INDEX ON public.notification_events(sent_at);
CREATE INDEX ON public.notification_events(apns_status) WHERE apns_status = 'pending';
CREATE INDEX ON public.notification_events(idempotency_key);

-- No RLS on notification_events (internal/Vapor-only table)
```

**Step 2: Backfill existing Amazon RDS device tokens**

One-time migration script (run via Vapor CLI command or psql):

```sql
-- Run against Supabase, pulling from Amazon RDS via dblink or external script
-- Simpler: export Amazon devices to CSV, import into Supabase via psql COPY

-- Map Amazon RDS devices → Supabase user_device_tokens
-- learn_user_id that is a valid UUID → user_id
-- learn_user_id = "anonymous" → anonymous_id = "anonymous", user_id = NULL

INSERT INTO public.user_device_tokens (
    device_token, user_id, anonymous_id, platform, app_version,
    apns_environment, is_active, last_seen, language, timezone,
    last_notified, created_at, updated_at
)
SELECT
    device_token,
    CASE WHEN learn_user_id ~ '^[0-9a-f-]{36}$' THEN learn_user_id::UUID ELSE NULL END,
    CASE WHEN learn_user_id = 'anonymous' THEN 'anonymous' ELSE NULL END,
    COALESCE(platform, 'ios'),
    COALESCE(app_version, 'unknown'),
    'production',     -- assume production for all existing tokens
    true,
    COALESCE(last_seen, NOW()),
    language,
    timezone,
    last_notified,
    COALESCE(created_at, NOW()),
    COALESCE(updated_at, NOW())
FROM amazon_rds_devices  -- substitute actual source
ON CONFLICT (device_token) DO NOTHING;
```

**Step 3: Add Supabase as second Fluent database in Vapor**

```swift
// configure.swift
// Add alongside existing Amazon RDS configuration
if let supabaseDBURL = Environment.get("SUPABASE_DATABASE_URL") {
    try app.databases.use(
        .postgres(url: supabaseDBURL, maxConnectionsPerEventLoop: 2),
        as: .supabase
    )
    // Run Supabase-targeted migrations
    app.migrations.add(CreateUserDeviceTokens(), to: .supabase)
    app.migrations.add(CreateNotificationPreferences(), to: .supabase)
    app.migrations.add(CreateNotificationEvents(), to: .supabase)
}
```

New env var required: `SUPABASE_DATABASE_URL` — the Supabase direct connection string (not pooler):
```
postgresql://postgres.[project-ref]:[password]@db.[project-ref].supabase.co:5432/postgres
```

**Step 4: New Fluent models targeting Supabase**

```swift
final class UserDeviceToken: Model, Content {
    static let schema = "user_device_tokens"
    // Use .supabase database
    static var defaultDatabase: DatabaseID? { .supabase }
    
    @ID(key: .id) var id: UUID?
    @OptionalField(key: "user_id") var userID: UUID?
    @OptionalField(key: "anonymous_id") var anonymousID: String?
    @Field(key: "device_token") var deviceToken: String
    @Field(key: "platform") var platform: String
    @Field(key: "app_version") var appVersion: String
    @Field(key: "apns_environment") var apnsEnvironment: String
    @Field(key: "is_active") var isActive: Bool
    @Field(key: "last_seen") var lastSeen: Date
    @OptionalField(key: "language") var language: String?
    @OptionalField(key: "timezone") var timezone: String?
    @OptionalField(key: "last_notified") var lastNotified: Date?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?
}
```

**Step 5: Dual-write in `POST /device/register`**

During cutover, the registration route writes to both databases:

```swift
// Write to Amazon RDS (existing behavior — unchanged)
let legacyDevice = Device(...)
try await legacyDevice.save(on: req.db(.default))  // explicit .default

// Write to Supabase (new)
let supabaseToken = UserDeviceToken(...)
try await supabaseToken.upsert(on: req.db(.supabase))
```

**Step 6: Cut push send reads to Supabase**

Update `/send-broadcast-push` and `/send-missed-users-push` to query `user_device_tokens` on `.supabase` instead of `devices` on `.default`.

Amazon `devices` is no longer read for sends. It still receives dual-write registration updates.

**Step 7: Validate and remove dual-write (1–2 weeks later)**

After confirming Supabase delivery counts match historical Amazon counts:
- Remove Amazon write from `POST /device/register`
- Amazon `devices` is now read-only
- Begin 30-day archive window

---

#### Phase 1C — Notification Service & Contracts (Week 2–3)
*Build the correct notification primitives on top of the Supabase foundation.*

**Backend tasks:**
- [ ] Implement `NotificationService` with centralized send logic (reads from Supabase `user_device_tokens`)
- [ ] Implement APNS error classification: `BadDeviceToken` / `Unregistered` → set `is_active = false` in Supabase; transient errors → retry up to 3x
- [ ] Log every send attempt to Supabase `notification_events` (status: pending → sent | failed | invalid_token)
- [ ] Implement `NotificationType` enum as a Swift type backing all send calls
- [ ] Add `DELETE /device/token` deregistration endpoint (sets `is_active = false` in Supabase `user_device_tokens`)
- [ ] Add `GET /notifications/preferences` — reads from Supabase `notification_preferences`
- [ ] Add `PUT /notifications/preferences` — writes to Supabase `notification_preferences`
- [ ] Standardize APNS payload: add `snaportho` custom data block with `notificationType`, `deepLink`, `eventId`, `category`, `version`
- [ ] Add `snaportho://` deep link format constant (not hardcoded per route)
- [ ] Update admin send routes to use `NotificationService` (typed, logged, deep-linked)

**iOS tasks:**
- [ ] Call `DELETE /device/token` on logout
- [ ] Add `apnsEnvironment: "production" | "sandbox"` to registration payload
- [ ] Register `snaportho://` URL scheme and handle all defined deep link paths
- [ ] POST to `POST /notifications/interaction` on notification open (pass `eventId` from payload)

**Definition of done:** 
- Supabase holds all device tokens; Amazon `devices` is dual-write fallback only
- Every send is logged in Supabase `notification_events`
- Invalid tokens are deactivated automatically
- Users can opt out per category via API
- Every notification has a type, deep link, and `eventId`
- No hardcoded tokens, paths, or copy in route handlers
- Sandbox APNS available for safe testing

---

### Phase 2 — Scheduled Notifications (2–3 weeks)
*Build the engine before the content.*

**Backend tasks:**
- [ ] Create `scheduled_notifications` table
- [ ] Create `notification_templates` table with initial templates
- [ ] Implement Vapor `ScheduledJob` to dispatch pending notifications
- [ ] Implement idempotency key check before insert and before send
- [ ] Implement quiet hours logic in `NotificationService`
- [ ] Implement frequency cap (max N per day per user)
- [ ] Implement retry logic for transient APNS failures
- [ ] Implement recurring notification scheduling (cron rule)
- [ ] Implement user-local-time scheduling via stored timezone
- [ ] `notification_preferences` migration + sync endpoint

**Definition of done:** Can schedule a notification for a user's 8am local time with idempotency, quiet hours, and frequency cap. Recurring daily notifications work. Failed sends retry automatically.

---

### Phase 3 — Engagement Notifications (3–4 weeks)
*Real content. Real engagement loops.*

**Backend tasks:**
- [ ] Daily OITE/learning question at 8am user-local (requires question database integration)
- [ ] Daily ortho pearl at 7am user-local
- [ ] CasePrep: detect cases scheduled for tomorrow → send reminder at 8pm night before
- [ ] CasePrep: detect incomplete prep → send nudge 4h after case_prep_log created without completion
- [ ] BroBot follow-up: 24h after BroBot session ended
- [ ] Streak reminder: if user hasn't opened app by 7pm and has an active streak
- [ ] Weekly progress summary: Sunday evening
- [ ] Inactivity reactivation: 7-day inactive → single reactivation push
- [ ] Onboarding activation: 24h after install with no activity

**iOS tasks:**
- [ ] Handle all new deep link destinations
- [ ] Background refresh for streak state
- [ ] Notification category actions (e.g. "Start Prep" as notification action button)

**Definition of done:** At least 5 of the above notification types active. Open rates > 15% on CasePrep/BroBot types. No user receives > 3 notifications per day.

---

### Phase 4 — Personalization Engine (4–6 weeks)

**Backend tasks:**
- [ ] User activity score table (last_active, streak_length, active_categories, weak_topics)
- [ ] Segment users by activity: power_user, regular, at_risk, lapsed
- [ ] Per-user notification timing optimization (send at time of historical opens)
- [ ] Weak area detection from OITE question history → send targeted pearl
- [ ] Recent BroBot topic → surface related content the next day
- [ ] Saved procedure reminder if not revisited in 7 days
- [ ] Attending preference alert when new preference added
- [ ] Notification frequency auto-adjustment based on open rate per user

**Definition of done:** Users receive notifications relevant to their activity. Open rates improve vs Phase 3 baseline.

---

### Phase 5 — Analytics & Optimization (ongoing)

**Backend tasks:**
- [ ] `notification_interactions` table fully wired
- [ ] Open rate / delivery rate per type tracked in notification_events
- [ ] Admin dashboard endpoint: `/admin/notifications/stats`
- [ ] A/B testing: support multiple templates per type, random assignment
- [ ] Notification health alerts: alert if delivery rate drops below 80%
- [ ] APNS token invalidity trending

**Definition of done:** Can measure open rate per notification type. Can run copy experiments. Have visibility into system health.

---

## Go / No-Go Recommendation

**Do NOT build Phase 3+ engagement notifications yet.**

The current foundation has critical reliability bugs (stale tokens, unauthenticated admin routes, synchronous sends, no logging, hardcoded credentials) that will cause failures at any scale and expose the server to misuse.

**Storage decision is resolved:** All new notification tables go in Supabase Postgres. The Amazon RDS `devices` table is migrated via dual-write cutover and archived after validation. This is the right long-term architecture because user IDs already come from Supabase, all other business data lives in Supabase, and Supabase gives real FKs, RLS, and future Realtime/Edge Function unlock for free.

**Recommended sequence:**

1. **Phase 1A (Day 1–2):** Fix the three critical security issues — auth the admin routes, remove `/debug/devices`, move APNS credentials to env vars. Zero app changes. One PR.

2. **Phase 1B (Week 1–2):** Create Supabase notification tables. Backfill Amazon device tokens. Dual-write `POST /device/register` to both databases. Cut push-send reads to Supabase. Monitor for 1–2 weeks.

3. **Phase 1C (Week 2–3):** Build `NotificationService`, wire `notification_events` logging, handle token invalidation, add deregister and preferences endpoints, standardize deep link payload.

4. **Phase 2 (2–3 weeks):** Add `scheduled_notifications` to Supabase. Vapor scheduled job for dispatch. Idempotency, quiet hours, frequency cap, retry logic.

5. **Phase 3 (3–4 weeks):** Engagement notifications. Every type typed, scheduled in Supabase, logged, deep-linked.

The total timeline to Phase 3 engagement notifications is approximately **7–10 weeks of backend work**. The work is additive — existing behavior is not broken at any step. The risk of not doing this is a notification system that silently fails, accumulates invalid tokens, provides no analytics, and delivers no measurable engagement value.

**Amazon RDS is not deleted during any of these phases.** The `donations` table stays there indefinitely. The `devices` table is archived 30 days after the Supabase cutover is validated. No data is lost.
