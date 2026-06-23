# SnapOrtho — Learning & BroBot Re-engagement Notification Strategy (Phase 2)

**Status:** Planning only. No code, no test sends, no production data modified.
**Supersedes:** The previous version of this document, which audited only the Vapor source tree and incorrectly concluded that BroBot/OITE/subscription data didn't exist. That conclusion was wrong — see Executive Summary.
**Method:** Read-only inspection of the live Supabase Postgres database via `.env.local` credentials (`SUPABASE_DATABASE_URL`, read-only session). No secrets printed. No rows modified. No notifications sent.

---

## Executive Summary

**The previous audit was wrong about the most important thing.** It concluded BroBot conversations, OITE-style content, training-level data, and subscription state didn't exist anywhere in this product. They do — in Supabase, in a schema this Vapor backend simply hadn't connected to yet until Phase 1. Connecting to it now reveals a substantially more mature product than the Vapor source tree alone suggested:

- **`brobot_conversations` / `brobot_messages` / `brobot_message_tags`** — a real, structured conversation log with topic/subtopic/body-region/procedure/concept-type tagging already populated (354 tag rows across 188 messages)
- **`branch_events` / `branch_outcomes` / `branch_questions` / `branch_topics`** — a fully-built follow-up-question recommendation engine that already tracks impressions, clicks, `continued_after_click`, `return_within_7d`, `abandoned`, and an `educational_success_score` per outcome. This is functionally a more sophisticated version of the "candidate queue" this brief asks for — for follow-up *content selection*, not push notifications, but the data model and instrumentation discipline already exist.
- **`user_profiles`** — `training_level`, `subspecialty_interest`, `pgy_year`, `grad_year`, `institution` — populated for 622 users, though with real data-quality issues (free-text inconsistency — see Signal Map)
- **`subscriptions` / `subscription_events` / `entitlement_overrides` / `user_daily_usage`** — a real subscription system. `plan_code = 'unlimited_brobot'` confirms "BroBot Unlimited" is a literal, already-named product tier, sold through both Stripe and Apple in-app purchase. Daily quota usage is tracked per user/guest.

**The new, accurate blocker is not missing data — it's adoption scale.** As of this audit: 320 users have a registered device token; only **8 users total** have ever had a BroBot conversation; only **2 of those 8** also have a registered device token; only **4 users** with a device token also have a subscription record. BroBot itself is early and lightly used. The notification system can be built correctly today, but a BroBot-follow-up push campaign launched this week would have an addressable audience of two people.

This changes the recommended sequencing from the previous draft: **Learning notifications (addressable to ~200 device-token-holding users with a profile) should lead v1, not follow it.** BroBot re-engagement should be built in parallel since the data fully supports it, but its near-term impact is capped by BroBot's current usage volume — and a part of this initiative should explicitly include *driving first-time BroBot trial* via notification, not just re-engaging existing BroBot users.

---

## Part 1 (continued): Supabase Schema Findings

### Identity model (confirmed via live joins, not inferred)

All user-referencing tables use the same `user_id UUID` pointing at Supabase `auth.users.id`. Verified by successfully joining `user_device_tokens.user_id` against `brobot_conversations.user_id`, `subscriptions.user_id`, and `user_profiles.user_id` — no mismatches, no separate ID space. **This is good news: there is one identity to design around, not several to reconcile.**

| Table | Role | Rows | Distinct users |
|---|---|---|---|
| `user_device_tokens` | Phase 1 — APNS tokens | 498 (360 with non-null `user_id`) | 320 |
| `brobot_conversations` | BroBot session container | 46 | 8 |
| `brobot_messages` | Individual chat turns | 188 | (subset of above 8) |
| `brobot_message_tags` | Topic/concept tagging per message | 354 | (subset of above 8) |
| `branch_events` / `branch_outcomes` | Follow-up question engine telemetry | 187 / 18 | small, overlaps BroBot users |
| `user_profiles` | Training level, specialty, institution | 622 | 622 |
| `subscriptions` | Stripe + Apple subscription state | 13 | 11 |
| `subscription_events` | Raw webhook event log | 85 | — |
| `entitlement_overrides` | Admin-granted comp access | 4 | 4 |
| `user_daily_usage` | Daily BroBot quota counter | 76 | small |
| `notification_preferences` | Phase 1 | **0** | 0 |
| `notification_delivery_attempts` | Phase 1 | **1** (status=`failed`) | — |

**Join feasibility (measured, not assumed):**

| Join | Users matched |
|---|---|
| device token ∩ user_profiles | **200** |
| device token ∩ brobot_conversations | **2** |
| device token ∩ subscriptions | **4** |

This single table is the most important finding in this document. **Learning notifications can address up to 200 real users today using existing data. BroBot follow-up notifications can address 2.**

### Subscription model (confirmed)

- `subscriptions.status` enum: `incomplete`, `active`, `past_due`, `canceled`, `unpaid`, `trialing`
- `subscriptions.plan_code`: only one value exists today — `unlimited_brobot` — confirming "BroBot Unlimited" is the actual product name, not a hypothetical
- `subscriptions.provider`: `stripe` (6 rows) and `apple` (7 rows) — **both purchase paths exist; any conversion-tracking logic must handle both**, not just Stripe
- `entitlement_overrides.type` enum: `hard_disable`, `unlimited_until`, `unlimited_permanent` — admin-grantable comp/ban states, independent of paid subscriptions
- **Important architectural note:** the Vapor backend's only Stripe webhook handler (`POST /stripe-webhook`) writes exclusively to the `donations` table. **Nothing in this Vapor repo writes to `subscriptions` or `subscription_events`.** Something else — likely a separate service or Supabase Edge Function — owns that table. `subscription_events.processed_at` being nullable suggests an event queue with an expected consumer; nothing currently consumes it from Vapor. **Any Phase 2 work that reacts to subscription changes should poll/read `subscriptions` directly rather than assume Vapor receives the webhook** — building a new webhook receiver for subscription state is out of scope for this notification project and shouldn't be conflated with it.

### Usage/quota model (confirmed)

- `user_daily_usage`: one row per `(user_id, usage_date, feature)`, `feature` is always `'brobot'` today, `count` ranges 1–32 (avg 2.6) across 76 rows
- `brobot_usage_events`: 616 rows, `outcome` distribution — `success` (585), `failure` (26), **`limit_hit` (5)** — confirms a real, already-firing quota-limit event exists. This is the exact signal the "usage limit reached" subscription trigger needs, and it already exists with zero new instrumentation.

### BroBot content/topic model (confirmed, more mature than assumed)

- `brobot_messages.mode` distribution: `or_prep` (64), `auto` (50), `oite` (27), `general` (25), `clinic` (11), `consult` (8), `fracture_call` (2), `research` (1) — **`oite` is a real, populated BroBot mode**, not a separate missing system. The prior audit's claim "no OITE table exists" was too narrow — OITE-style interaction happens *through* BroBot, tagged by mode, not in a standalone question bank.
- `brobot_message_tags.topic` top values: `concept` (53), `anatomy` (49), `complication` (35), `procedure` (30), `surgery` (19), `trauma` (15), `classification` (11), `oite` (11), `diagnosis` (8), `fracture` (7), `imaging` (6), `tka` (4) — **topic extraction is already happening and already populated.** "Recently studied topic" follow-ups are buildable today by querying this table, not a future capability.
- `branch_topics` / `branch_questions`: 35 topics, 135 candidate follow-up questions already exist, each with a `success_score`, `usage_count`, `click_count` — a working content bank for "5 board-style questions on X" already exists structurally.

### Data quality issues found (must be handled, not blocking)

- `user_profiles.training_level` is free text with real inconsistency: `'MD/DO Resident'`, `'PGY-1'`, `'pgy1'` (lowercase, in `branch_events.training_level` — a different column on a different table with different conventions), trailing-space variants (`'Ortho '` vs `'Ortho'`), and a non-ASCII hyphen variant (`'PA‑C'` vs `'PA-C'`). **Any segmentation logic must normalize this — do not match on exact string equality.**
- `user_profiles.subspecialty_interest` is similarly inconsistent free text (`'Ortho'`, `'Orthopedics'`, `'Orthopaedics'`, `'Orthopedic Surgery'`, `'Orthopaedic Surgery'` — five spellings for what's probably the same intent in many cases) — same caveat.
- `user_profiles.is_profile_complete`: 460 of 622 rows are `NULL` (neither true nor false) — most users have *some* profile data but never completed a formal "profile complete" flow. Treat `NULL` as "unknown," not as "incomplete."

---

## Part 2: Available Signal Map

| Signal | Source table.column | Freshness | Reliability | Powers v1? | New instrumentation needed? |
|---|---|---|---|---|---|
| Last app open (coarse) | `user_device_tokens.last_seen_at` | Updates on device re-registration only, not every session | Medium — coarse, not session-level | ✅ Yes | No |
| Last BroBot use | `brobot_conversations.updated_at` (max per user) | Real-time as conversations happen | High | ✅ Yes (for the 8 users with BroBot history) | No |
| Last BroBot conversation topic | `brobot_message_tags.topic`/`subtopic`/`procedure` joined to latest message in latest conversation | Real-time | High — already tagged | ✅ Yes | No |
| BroBot mode | `brobot_messages.mode` | Real-time | High | ✅ Yes | No |
| BroBot response depth | `brobot_messages.response_depth` | Real-time | Low signal today — only one value (`standard`) observed across all 188 rows | ⚠️ Not yet — no variance to key off of | No (data exists, just not yet varied) |
| Conversation created/updated time | `brobot_conversations.created_at`/`updated_at` | Real-time | High | ✅ Yes — this is the basis for 24h/72h/7d triggers | No |
| Message count per conversation | `COUNT(*) FROM brobot_messages GROUP BY conversation_id` | Real-time (computed) | High | ✅ Yes | No (computed, not stored — fine for v1 query volume) |
| Free quota usage | `user_daily_usage.count` + `brobot_usage_events.outcome = 'limit_hit'` | Real-time | High — `limit_hit` event already fires | ✅ Yes | No |
| Subscription status | `subscriptions.status`, `plan_code`, `current_period_end` | Updated by whatever external process owns this table (not Vapor) | High, but **freshness depends on a system outside this audit's visibility** — verify the writer's update latency before relying on it for time-sensitive triggers like trial-ending | ✅ Yes, with the above caveat | No |
| Trial status | `subscriptions.status = 'trialing'` + `current_period_end` | Same caveat as above | High | ✅ Yes | No |
| Training level | `user_profiles.training_level` | Static, set at profile creation/edit | Medium — free-text inconsistency (see Data Quality) | ⚠️ Yes, but normalize first | Light — needs a normalization mapping, not new collection |
| Specialty/procedure interest | `user_profiles.subspecialty_interest` | Static | Low-medium — sparse (191 empty string + 154 null out of 622) and inconsistent | ⚠️ Partial — usable for ~30% of users with a real value | Same normalization need |
| Recent CasePrep use | **Not found** — `caseprep_reviewers`/`caseprep_section_reviews` exist but track *content review workflow* (admin/reviewer activity), not end-user CasePrep usage | N/A | N/A | ❌ No | Yes — no end-user CasePrep activity table exists in this schema |
| Recent OITE use | `brobot_messages.mode = 'oite'` (proxy, not a dedicated table) | Real-time | Medium — usable as a proxy via BroBot mode, not a true question-bank-with-answers signal | ⚠️ Partial | Possibly, if true question-level scoring is wanted later |
| Notification token existence | `user_device_tokens` (Phase 1) | Real-time | High | ✅ Yes | No |
| Notification preference status | `notification_preferences` (Phase 1) | **Currently empty — 0 rows** | N/A yet | ✅ Mechanism ready, no real data yet | No — will populate naturally as users hit `GET /notifications/preferences` |

---

## Part 3: V1 Learning Notification Plan

### Why Learning leads v1 (not BroBot follow-up)
200 addressable users (device token + profile) vs. 2 for BroBot. This is the single largest practical finding in this audit and should override the prior document's "BroBot follow-up is highest ROI" framing for the *first* release. BroBot follow-up remains the better long-term lever — see Part 4 — but only once BroBot adoption grows, partly *because of* what Learning notifications drive.

### Notification types (v1)

| Type | Eligibility | Content source |
|---|---|---|
| **Daily High-Yield Pearl** | Any user with a non-invalidated, opted-in device token | Curated static content calendar (new, small — does not require new schema beyond the candidate queue) |
| **OITE-style Quick Question** | Same | Pulled from `branch_questions` (135 already exist, tagged by `branch_topics`) — re-use existing content rather than building a new question bank |
| **Recently Studied Topic Follow-up** | User has ≥1 `brobot_message_tags` row from the last 7 days | `brobot_message_tags.topic`/`procedure` for the user's most recent tagged message |
| **Training-Level-Specific Reminder** | User has a normalized, non-null `training_level` | Static content filtered by normalized training-level bucket (e.g., student vs. resident vs. fellow/attending) |

### Eligibility rules
- Must have an active (`invalidated_at IS NULL`), opted-in (`receive_notifications = true`) device token in `user_device_tokens`
- Must have `notification_preferences` row for `category = 'learning'` either absent (defaults enabled per Phase 1) or explicitly `enabled = true`
- Respect `quiet_hours_start`/`quiet_hours_end` if set
- "Recently Studied Topic" requires a `brobot_message_tags` row within the trailing 7 days for that user — falls back to Daily Pearl if none

### Frequency
- **1 per day, fixed user-local send time** (default 7:00 AM, already supportable via existing `timezone` field)
- Selection order when multiple types are eligible: Recently Studied Topic > Training-Level Reminder > OITE Quick Question > Daily Pearl (most personalized first)

### Copy examples
- Daily Pearl: *"Pearl of the day: tension band wiring resists which force?"*
- OITE Quick Question: *"60-second OITE question — open to answer."*
- Recently Studied Topic: *"Still thinking about TKA exposure? Here's a quick follow-up."*
- Training-level (student bucket): *"Starting your ortho rotation? Today's pearl is exam-relevant."*

### Deep links
| Type | Link |
|---|---|
| Daily Pearl | `snaportho://learn/pearl/{pearlId}` |
| OITE Quick Question | `snaportho://learn/question/{branchQuestionId}?mode=recall` |
| Recently Studied Topic | `snaportho://brobot?topic={topicSlug}&autoOpen=true` |
| Training-Level Reminder | `snaportho://learn/pearl/{pearlId}?level={normalizedLevel}` |

### Required tables
- New: `notification_candidates`, `notification_templates` (Part 5)
- Existing, read-only: `brobot_message_tags`, `branch_questions`, `branch_topics`, `user_profiles`, `user_device_tokens`, `notification_preferences`

### Scheduler behavior
A recurring job (every 15–60 min) scans for users whose local time matches their preferred send hour, generates one candidate per eligible user per day (idempotency key: `user_id + date + 'learning'`), inserts into `notification_candidates`, and a separate dispatch pass sends the highest-ranked pending candidate per user via the existing `NotificationService`.

### Analytics events
`notification.scheduled`, `notification.sent`, `notification.failed`, `notification.opened`, `notification.deep_link_completed` (all already specified in Phase 1's data model; `notification_interactions` table — referenced in Phase 1 docs as planned, not yet built — needs to ship as part of Phase 2A, see roadmap)

### Failure modes
- No eligible content for a training-level bucket → fall back to Daily Pearl, never skip the day silently
- `brobot_message_tags` query returns nothing for "Recently Studied" → fall back per the selection order above
- Device token invalidated mid-cycle → existing Phase 1 `NotificationService` already handles this (auto-invalidation on `BadDeviceToken`/`Unregistered`)

---

## Part 4: V1 BroBot Re-engagement Plan

**Scope caveat, stated once and binding for this whole section:** every trigger below is real and buildable today against real data — but the current addressable audience is **2 users**. Ship this in parallel with Learning notifications, not instead of them, and treat its early metrics as directional, not conclusive, until BroBot adoption grows (partly via the Learning notifications driving people toward BroBot for the first time — see the new "First BroBot Trial Nudge" type below, added because the data revealed this gap).

### 24-Hour Follow-Up
- **Eligibility:** `brobot_conversations.updated_at` between 22–26 hours ago, user has an active device token, `category = 'brobot'` preference not disabled, no follow-up already sent for this `conversation_id` (idempotency key: `user_id + conversation_id + 'followup_24h'`)
- **Suppression:** none beyond the standard cooldown (Part 6)
- **Cooldown:** 48h minimum between any two `brobot` category sends to the same user
- **Copy:** *"Want 5 board-style questions on {topic}?"* — `{topic}` from the most common `brobot_message_tags.topic` value in that conversation
- **Deep link:** `snaportho://brobot?conversationId={id}&autoOpen=true`
- **Schema needs:** none new — `brobot_conversations` + `brobot_message_tags` already sufficient
- **Analytics:** `notification.sent` with `notification_type=brobot.followup_24h`; track open → `brobot_conversations` row touched within 1h of open as a conversion proxy

### 72-Hour Recall
- **Eligibility:** conversation 70–76h old, no 24h follow-up was opened (if it was opened, the user already re-engaged — don't send a redundant recall)
- **Copy:** *"Can you still classify {topic}?"* (uses `concept_type`/`classification` tag when present, else generic recall framing)
- **Deep link:** same pattern as above

### Abandoned Conversation Recovery
- **Detectability, confirmed:** `branch_outcomes.abandoned` is a real, populated boolean column (currently all 18 existing rows show `False`, meaning no abandonment has been recorded yet — but the column and the underlying detection logic already exist in the `branch_outcomes` pipeline). **Re-use this column rather than building new abandonment-detection logic** — if the existing system hasn't flagged anything as abandoned yet, that's a true negative, not a missing capability.
- **Eligibility:** `branch_outcomes.abandoned = true` for a conversation, no recovery notification sent yet for that `conversation_id`
- **Copy:** *"Still there? Pick up where you left off."*
- **Deep link:** `snaportho://brobot?conversationId={id}&autoOpen=true`

### Free-User Usage-Limit Conversion Nudge
- **Eligibility:** `brobot_usage_events.outcome = 'limit_hit'` for the user today, user does NOT have an `active`/`trialing` subscription row, no usage-limit nudge sent in the last 7 days
- **Copy:** *"You've used today's free BroBot questions. Unlock unlimited access to keep going."*
- **Deep link:** `snaportho://subscription?source=usage_limit`
- **Schema needs:** none new — `brobot_usage_events.outcome = 'limit_hit'` already fires today

### High-Engagement Free-User Upgrade Nudge
- **Eligibility:** ≥3 `brobot_conversations` in the trailing 7 days, no active subscription, no conversion nudge of any kind sent in the last 14 days
- **Copy:** *"You're one of our most active BroBot users. See what Unlimited unlocks."*
- **Deep link:** `snaportho://subscription?source=high_engagement`

### NEW — First BroBot Trial Nudge (added based on this audit's findings, not in the original brief)
- **Why this is needed:** the data shows a large gap between users who have a device token (320) and users who've ever tried BroBot (8). Closing this gap is itself a DAU/conversion lever the original brief didn't anticipate because it assumed BroBot already had broad usage.
- **Eligibility:** device token registered ≥3 days ago, zero rows in `brobot_conversations` for that user, not sent this nudge before (one-time only)
- **Copy:** *"Meet BroBot — ask anything about your next case or OITE topic."*
- **Deep link:** `snaportho://brobot`
- **This is a one-time onboarding nudge, not a recurring campaign — cap at exactly one send per user, ever.**

### Subscription conversion tracking (cross-cutting for all four conversion-oriented types above)
Tag every conversion-prompt send's `notification_delivery_attempts.metadata` with `{"conversion_trigger": "<type>"}`. When a `subscriptions` row transitions to `active`/`trialing` for a user, check whether any conversion-prompt notification was opened (`notification_interactions`) within the preceding 48 hours, and attribute the conversion to that trigger type if so. This requires `notification_interactions` to exist (Part 5/roadmap) and a scheduled or triggered job to do the attribution join — not a real-time requirement.

---

## Part 5: Candidate Queue & Schema Design

### `notification_candidates`
| Column | Type | Purpose |
|---|---|---|
| `id` | uuid pk | |
| `user_id` | uuid, FK → `auth.users(id)` | |
| `source_type` | text | `learning_daily`, `learning_recent_topic`, `brobot_followup_24h`, `brobot_recall_72h`, `brobot_abandoned`, `brobot_first_trial`, `conversion_usage_limit`, `conversion_high_engagement` |
| `source_ref_id` | uuid, nullable | conversation_id / question_id / pearl_id this candidate is about |
| `category` | text | maps to existing `NotificationCategory` (`learning`, `brobot`, `product`) |
| `priority_score` | integer | computed at insert time, see Part 6 |
| `payload` | jsonb | title/body template inputs |
| `eligible_at` | timestamptz | earliest send time |
| `expires_at` | timestamptz | candidate becomes invalid after this |
| `status` | text | `pending`, `sent`, `expired`, `superseded`, `cooldown_blocked` |
| `created_at` | timestamptz | |

**Uniqueness/idempotency:** `UNIQUE (user_id, source_type, source_ref_id)` — prevents the scanning job from generating duplicate candidates for the same underlying event on every run.
**Indexes:** `(status, eligible_at)` partial where `status='pending'`; `(user_id)`.
**Retry behavior:** failed sends are not retried as new candidates — the existing `notification_delivery_attempts` retry semantics from Phase 1 (`status=failed`, `error_code`) already cover the APNS layer; this table only governs *candidate selection*, not delivery retries.
**Expiration:** enforced at dispatch time — a `brobot_followup_24h` candidate not sent within its 22–26h window (because the daily cap was already used) should flip to `expired`, not fire late and confuse the user about timing.
**Deduplication:** the unique constraint above, plus a dispatch-time check that no `sent` candidate exists for the same `(user_id, category)` within the cooldown window (Part 6).

### `notification_templates`
| Column | Type |
|---|---|
| `id` | uuid pk |
| `notification_type` | text, unique |
| `category` | text |
| `title_template` | text (supports `{{variable}}`) |
| `body_template` | text |
| `deeplink_template` | text |
| `is_active` | boolean |
| `version` | integer |

### `notification_interactions` (referenced but not yet built in Phase 1 — required for Phase 2)
| Column | Type |
|---|---|
| `id` | uuid pk |
| `delivery_attempt_id` | uuid, FK → `notification_delivery_attempts(id)` |
| `user_id` | uuid |
| `action` | text — `opened`, `dismissed`, `deep_link_completed` |
| `app_version` | text |
| `interacted_at` | timestamptz |

### `notification_user_state` (new — tracks per-user daily/weekly send counters for cap enforcement)
| Column | Type |
|---|---|
| `user_id` | uuid pk |
| `sends_today` | integer |
| `sends_this_week` | integer |
| `last_sent_at` | timestamptz |
| `last_sent_category` | text |
| `day_bucket` | date (for reset logic) |
| `week_bucket` | date |

This table exists so the ranking engine doesn't need to re-scan `notification_delivery_attempts` on every candidate-selection pass — it's a denormalized counter, reset by the same scheduler job.

### Quiet hours, max/day, max/week
Already specified in `notification_preferences` (quiet hours) — reused as-is. Caps enforced via `notification_user_state` (Part 6).

---

## Part 6: Ranking & Suppression Model

### Hard rules
- **Max 1 notification/day per user**, except `system` category (bypasses all caps, per Phase 1's existing `NotificationCategory.bypassesFrequencyCap`)
- **Max 3/week per user**
- **Product/conversion notifications: max 1/week**, counted separately from the general 3/week cap (i.e., a conversion send still counts toward the 3/week total, but no more than 1 of those 3 may be a conversion type)
- **BroBot follow-up outranks daily learning** when both are eligible the same day
- **Product notifications only fire if `category=product` preference is explicitly enabled** (matches the already-implemented Phase 1 default — `product.defaultEnabled = false`)
- **No PHI or patient identifiers in any title/body** — enforced by convention today (Phase 1 finding); recommend a lightweight keyword-scan guard in the template-rendering step before Phase 2 ships (e.g., reject any rendered string containing a name-shaped pattern or an MRN-shaped numeric pattern) since Phase 2 introduces dynamic, topic-driven copy for the first time — Phase 1's only dynamic content was generic broadcast text.

### Priority scores
| Source type | Score |
|---|---|
| `brobot_abandoned` | 100 |
| `brobot_followup_24h` | 90 |
| `brobot_recall_72h` | 70 |
| `conversion_usage_limit` | 60 — moved above learning because it's the single most time-sensitive, highest-intent moment in the whole system |
| `learning_recent_topic` | 50 |
| `brobot_first_trial` | 45 |
| `learning_daily` | 40 |
| `conversion_high_engagement` | 15 |

### Cooldowns
- Same `source_type`, same user: 48h minimum
- Any `brobot` category send: 12h minimum since the last `brobot` category send
- Any conversion-type send: 7 days minimum since the last conversion-type send (enforces the 1/week product cap directly, not just via counting)

### Selection algorithm
Once per day per user at their preferred local send hour: gather `pending`, non-expired candidates → filter by preference/quiet-hours/cooldown → sort by `priority_score` descending → send the top one via `NotificationService` → mark the rest `superseded` (retained for analytics on near-misses, not deleted).

---

## Part 7: Analytics Plan

Reuses the event names already established in Phase 1's design (`notification.scheduled`, `.sent`, `.failed`, `.skipped`) and adds, once `notification_interactions` exists:

- `notification.opened`
- `notification.deep_link_completed`
- `notification.session_started` — a BroBot conversation or learning content view begins within 10 minutes of the open (the actual proof the push drove usage, not just an app foreground)
- `notification.conversion_attributed` — computed (not directly logged) by joining a `subscriptions` status transition to a prior conversion-type notification open within 48h

### Product metrics to track from day one
- **DAU uplift:** notified vs. non-notified cohort, same day
- **BroBot trial rate:** % of `brobot_first_trial` recipients who create a `brobot_conversations` row within 7 days — this is the single most important new metric this audit's findings justify, since it directly measures whether Learning/onboarding notifications are growing BroBot's currently-tiny user base
- **Retention (D7/D30):** reserve a 5–10% permanent holdout group (no notifications at all) from day one — cannot be retrofitted later
- **Subscription conversion:** time-to-convert split by which conversion trigger (if any) preceded it within 48h

---

## Part 8: Subscription Conversion Strategy

(Consolidated from Part 4 — repeated here per the requested document structure, not new content.)

| Trigger | Eligibility | Copy | Deep link |
|---|---|---|---|
| Free user hits quota | `brobot_usage_events.outcome='limit_hit'` today, no active subscription | "You've used today's free BroBot questions. Unlock unlimited access to keep going." | `snaportho://subscription?source=usage_limit` |
| Repeated BroBot sessions | ≥3 conversations in 7 days, no active subscription | "You're one of our most active BroBot users. See what Unlimited unlocks." | `snaportho://subscription?source=high_engagement` |
| Returns from a BroBot notification | User opened a `brobot_followup_24h`/`recall_72h` push and started a new message within the session | (no separate push — this is a deep-link landing state, not its own notification; tag the resulting conversion if it occurs within 48h) | n/a |
| Trial ending soon | `subscriptions.status='trialing'` AND `current_period_end` within 24h | "Your trial ends today. Keep unlimited BroBot access." | `snaportho://subscription?source=trial_ending` |
| Trial expired | `subscriptions.status` transitions from `trialing` to `canceled`/`incomplete` | "Your trial has ended. Resubscribe to keep unlimited access." | `snaportho://subscription?source=trial_expired` |
| High-intent mode use (OR Prep / OITE / Research) | ≥2 messages in `mode IN ('or_prep','oite','research')` within 7 days, no active subscription | "Heavy OR Prep user? Unlimited removes your daily question cap." | `snaportho://subscription?source=high_intent_mode` |

**Explicitly excluded per the brief:** no generic marketing blasts, no "buy now" copy untethered to a specific behavioral moment.

---

## Part 9: Implementation Roadmap

### Phase 2A — Data verification + scheduler foundation
- **Files touched:** `Sources/SnapOrthoBackend/Notifications/Migrations/CreateNotificationCandidates.swift`, `CreateNotificationInteractions.swift`, `CreateNotificationUserState.swift`, `CreateNotificationTemplates.swift`; a new `Sources/SnapOrthoBackend/Notifications/Services/CandidateScheduler.swift`
- **Migrations:** the 4 tables in Part 5, targeting `.notifications` (Supabase) exactly as Phase 1 did
- **Endpoints:** none new yet — this phase is internal plumbing
- **Background jobs:** a Vapor `AsyncScheduledJob` running every 15 min, initially doing nothing but logging candidate counts (no real sends) — validates the scheduler loop itself before any user-facing behavior ships
- **iOS changes:** none yet
- **Test plan:** unit tests for idempotency-key uniqueness, expiration logic, cooldown logic — all against a test database, no live sends
- **Launch criteria:** scheduler runs reliably for 48h in staging with zero duplicate candidates and zero crashes
- **Rollback plan:** disable the scheduled job (single feature flag/env var); tables are additive, no risk to existing data

### Phase 2B — Static daily learning v1
- **Files touched:** `LearningCandidateGenerator.swift` (new), seed data for `notification_templates`
- **Migrations:** none beyond 2A
- **Endpoints:** none new (uses existing `NotificationService.sendToUser`)
- **Background jobs:** extend the 2A scheduler to actually generate + dispatch `learning_daily` candidates
- **iOS changes:** register `snaportho://learn/pearl/{id}` and `snaportho://learn/question/{id}` deep links
- **Test plan:** end-to-end test with a seeded test user, mock APNS sender (per Phase 1's existing `MockAPNSSender` pattern), assert exactly one send/day
- **Launch criteria:** 1-week soft launch to an internal test cohort, confirm no duplicate or over-cap sends, confirm `notification_delivery_attempts` rows match expectations
- **Rollback plan:** feature flag to disable `learning_daily` candidate generation; no data loss risk

### Phase 2C — BroBot follow-up candidates
- **Files touched:** `BroBotCandidateGenerator.swift` (new)
- **Migrations:** none beyond 2A
- **Endpoints:** none new
- **Background jobs:** scan `brobot_conversations`/`brobot_message_tags`/`branch_outcomes` on the existing scheduler cadence
- **iOS changes:** `snaportho://brobot?conversationId={id}&autoOpen=true` deep link handling
- **Test plan:** seed synthetic conversations at 24h/72h ages in a test DB, confirm correct candidate generation and expiration
- **Launch criteria:** given the 2-user addressable audience today, launch criteria should be "works correctly," not "moves a metric" — defer impact measurement until BroBot adoption grows
- **Rollback plan:** feature flag; no data risk

### Phase 2D — Conversion nudges
- **Files touched:** `ConversionCandidateGenerator.swift` (new)
- **Migrations:** none beyond 2A
- **Endpoints:** none new — reads `subscriptions`/`user_daily_usage`/`brobot_usage_events` directly
- **Background jobs:** extend scheduler to scan for `limit_hit` events and high-engagement patterns
- **iOS changes:** `snaportho://subscription?source={trigger}` deep link, ensure the subscription paywall screen reads the `source` param for its own analytics
- **Test plan:** synthetic quota-hit and trial-expiry scenarios in test DB
- **Launch criteria:** verify the 1/week conversion cap holds under load testing with multiple simultaneously-eligible triggers for one user
- **Rollback plan:** feature flag per trigger type (allows disabling just one trigger without affecting others)

### Phase 2E — Personalization
- **Files touched:** training-level normalization utility, specialty-interest normalization utility
- **Migrations:** possibly a `user_profiles` normalization view (read-only, doesn't modify the source table)
- **Endpoints:** none new
- **Background jobs:** none new — personalization is a filter applied within existing generators
- **iOS changes:** none required (server-side personalization only)
- **Test plan:** normalization unit tests covering every distinct raw value observed in this audit (`'PGY-1'`, `'pgy1'`, `'MD/DO Resident'`, etc.)
- **Launch criteria:** normalization correctly buckets ≥95% of non-null `training_level` values observed in production
- **Rollback plan:** personalization filters are additive refinements to existing generators — disabling them falls back to Phase 2B/C/D's unpersonalized behavior, no data risk

---

## Risks / Blockers

| Risk | Severity | Mitigation |
|---|---|---|
| BroBot's addressable audience is 2 users today | High (for BroBot follow-up's near-term impact, not for build risk) | Sequence Learning notifications first; add the First BroBot Trial Nudge to grow the BroBot user base in parallel |
| Vapor doesn't own `subscriptions` writes | Medium | Read-only polling of `subscriptions`/`subscription_events` is sufficient for all triggers in this plan; do not build a new webhook receiver as part of this project |
| `training_level`/`subspecialty_interest` free-text inconsistency | Medium | Normalization step required before any segmentation logic ships (Phase 2E) — do not personalize on raw string match before then |
| `notification_preferences` has zero real rows today | Low | Expected — Phase 1 just shipped; rows populate lazily as users hit the preferences endpoint or receive their first notification |
| Subscription state freshness from an external writer is unverified | Medium | Before relying on `current_period_end` for time-sensitive trial-ending pushes, confirm the actual update latency of whatever process writes `subscriptions` |
| No holdout/control group built into the original Phase 1 design | Medium | Must be added explicitly in Phase 2A — cannot be retrofitted after the fact for clean retention measurement |

---

## Exact Recommended Implementation Prompt for Phase 2A

```
Implement Phase 2A of the SnapOrtho notification system: the candidate/scheduler foundation, with no user-facing sends yet.

Context:
- Phase 1 shipped: user_device_tokens, notification_preferences, notification_delivery_attempts all live in
  Supabase Postgres (.notifications database ID in Vapor's Fluent config). NotificationService handles all
  APNS sends with delivery logging and token invalidation. Categories: system, learning, caseprep, brobot,
  reminders, product.
- A schema audit of the live Supabase database (read-only, via .env.local) confirmed real BroBot conversation
  data (brobot_conversations, brobot_messages, brobot_message_tags), a real subscription system (subscriptions,
  subscription_events, entitlement_overrides, plan_code='unlimited_brobot'), and real usage-quota tracking
  (user_daily_usage, brobot_usage_events with outcome='limit_hit' already firing).
- Vapor does NOT currently write to subscriptions/subscription_events — something else owns that table. Do not
  build a new webhook receiver. Read-only access is sufficient for this phase.
- Addressable audience today: ~200 users have both a device token and a user_profiles row (Learning-eligible);
  only 2 users have both a device token and a BroBot conversation (BroBot-follow-up-eligible). This phase builds
  infrastructure for both, but expect Learning to be the first to show measurable impact.

Phase 2A scope:
1. Create 4 new Supabase-targeted Fluent migrations (database ID .notifications, same pattern as Phase 1):
   - notification_candidates: id, user_id, source_type, source_ref_id (nullable uuid), category, priority_score
     (int), payload (jsonb), eligible_at, expires_at, status (pending/sent/expired/superseded/cooldown_blocked),
     created_at. UNIQUE (user_id, source_type, source_ref_id). Index (status, eligible_at) partial where
     status='pending'. Index (user_id).
   - notification_templates: id, notification_type (unique), category, title_template, body_template,
     deeplink_template, is_active, version, created_at, updated_at.
   - notification_interactions: id, delivery_attempt_id (FK -> notification_delivery_attempts), user_id, action
     (opened/dismissed/deep_link_completed), app_version, interacted_at.
   - notification_user_state: user_id (pk), sends_today, sends_this_week, last_sent_at, last_sent_category,
     day_bucket (date), week_bucket (date).

2. Add a Vapor AsyncScheduledJob (every 15 minutes) that, in this phase, ONLY:
   - Logs the count of pending notification_candidates rows (there will be zero, since no generator exists yet)
   - Resets notification_user_state.sends_today/sends_this_week when day_bucket/week_bucket roll over
   - Does NOT generate any candidates and does NOT send anything — this phase validates the scheduler loop
     itself runs reliably before any candidate-generation or dispatch logic is added in Phase 2B.

3. Add a reusable CandidateRanking helper (pure functions, no I/O) implementing the priority scores and cooldown
   rules from this document's Part 6 (Ranking & Suppression Model) — e.g., brobot_abandoned=100,
   brobot_followup_24h=90, conversion_usage_limit=60, learning_daily=40, etc. — and the cap rules (max 1/day,
   max 3/week, max 1/week for product/conversion category, system bypasses caps). This will be consumed by
   Phase 2B/C/D's generators but has no behavior of its own yet — write it now so generators in later phases
   just call into it rather than duplicating the rules.

4. Add a 5-10% permanent holdout group mechanism: a stable hash of user_id determines holdout membership
   (must be deterministic and never reassigned). Store the holdout flag somewhere queryable (a column on
   notification_user_state is fine: is_holdout boolean). This MUST exist before Phase 2B ships any real sends —
   it cannot be added retroactively without losing clean measurement.

5. Tests:
   - Migration idempotency (running twice doesn't duplicate constraints)
   - Unique constraint on (user_id, source_type, source_ref_id) rejects duplicates
   - CandidateRanking unit tests covering every priority score and cooldown rule in Part 6
   - Holdout assignment is deterministic (same user_id always produces the same holdout result)
   - Scheduler job runs without error against an empty candidates table

Constraints:
- Phase 2A only — no candidate generation logic, no real sends, no iOS changes.
- All new tables target the .notifications (Supabase) Fluent database ID, exactly like Phase 1.
- Do not write to subscriptions or subscription_events — read-only in future phases, untouched in this one.
- Do not modify user_profiles, brobot_conversations, or any other pre-existing product table.
- All code must compile and existing tests must continue passing.
```
