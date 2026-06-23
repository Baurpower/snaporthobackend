# SnapOrtho — Notification Phase 2B Implementation

**Status:** Implemented, builds clean (debug + release). Live DB verification blocked by Amazon RDS unreachability in this sandbox — see [Test Results](#test-results) for the honest accounting.
**Scope:** Daily learning + first-BroBot-activation candidate generation. Candidates only — no broad automatic sends.

---

## What shipped

| Piece | File(s) |
|---|---|
| `notification_type` column on candidates | `Migrations/AddNotificationTypeToCandidates.swift` |
| Granular holdout flags | `Migrations/AddGranularHoldoutColumns.swift` |
| Deterministic recurring candidate refs | `Services/DeterministicCandidateRef.swift` |
| Next-morning scheduling | `Services/NextMorningScheduler.swift` |
| Candidate generator | `Services/LearningCandidateGenerator.swift` |
| `learning_oite_question` source type | `Services/CandidateRanking.swift` (extended) |
| Template seeding | `Commands/SeedNotificationTemplatesCommand.swift` |
| Candidate generation CLI | `Commands/GenerateLearningCandidatesCommand.swift` |
| Dispatch CLI (the missing Phase 2A piece) | `Commands/ProcessScheduledNotificationsCommand.swift` |
| Tests | `Tests/.../NotificationPhase2BTests.swift` |

---

## Templates seeded

| `notification_type` | Category | Title | Body | Deep link |
|---|---|---|---|---|
| `learning.daily_pearl` | `learning` | Today's Ortho Pearl | A quick high-yield review is ready. | `snaportho://brobot?mode=oite&source=notification_daily_pearl` |
| `learning.oite_question` | `learning` | Daily OITE Question | Test yourself with one high-yield ortho question. | `snaportho://brobot?mode=oite&source=notification_oite_daily` |
| `brobot.first_try` | `brobot` | Try BroBot in 60 seconds | Ask one ortho question or start a quick OITE review. | `snaportho://brobot?source=notification_first_try` |

**Note:** the spec listed two body-copy variants for `learning.daily_pearl` ("A quick high-yield review is ready." / "Build your ortho habit in 60 seconds."). Only the first is seeded — `notification_templates` has one `body_template` per row, and rotating variants wasn't asked for explicitly elsewhere in this phase, and the prompt's own analytics section says "design but do not overbuild." Supporting variants (via `version` increments or a separate variants table) is a clean Phase 2C+ addition if A/B testing copy becomes a priority.

Seeding is idempotent — upserts by `notification_type`, never inserts a duplicate row. Run via:

```bash
swift run SnapOrthoBackend seed-notification-templates
```

---

## Design decision: type-selection priority (read before relying on this)

The spec's literal priority list is:
```
1. device + profile + no BroBot conversations → brobot.first_try
2. device + profile                            → learning.daily_pearl
3. training level available                    → learning.oite_question
```

Taken as strict "always prefer the lower number," this makes `oite_question` **unreachable**: anyone who qualifies for it (device + profile + training_level) is a strict subset of who qualifies for `daily_pearl` (device + profile alone), so `daily_pearl` would always win and `oite_question` would never fire.

**What's implemented instead:** `first_try` still wins outright when applicable (matches bullet 1 exactly — this is the one explicitly tested case: "user with no BroBot history gets first_try priority"). For everyone else, the generator prefers the **more personalized** type when the data exists: `oite_question` if `training_level` is present and non-blank, `daily_pearl` otherwise. This is implemented in `LearningCandidateGenerator.selectCandidateType` with the reasoning spelled out in a doc comment there.

**If this reading is wrong**, the fix is localized to that one method — flagging it here explicitly so it's easy to override.

---

## Candidate generator behavior

One candidate created per eligible user per run (not all three types at once) — picked by the priority logic above. Each candidate:

- Inserted into `notification_candidates` only — never touches `notification_delivery_attempts`.
- `payload` (JSONB-equivalent `[String: String]`) includes: `title`, `body`, `deeplink` (all pulled from the matching `notification_templates` row), `template_id`, `template_type`, `source` (`first_brobot_try` / `daily_pearl` / `oite_question`), `version`.
- `eligible_at` = next 8 AM in the user's device timezone (from `user_device_tokens.timezone`, the most recently updated row with a non-null timezone for that user) if known, else 9 AM America/New_York. This column serves as `scheduled_for` from the spec — Phase 2A already named it `eligible_at` with that exact meaning, so no redundant column was added.
- `expires_at` = `eligible_at` + 12 hours.
- `status = pending`.

### Idempotency — the NULL-uniqueness fix

Phase 2A's unique index is `UNIQUE(user_id, source_type, COALESCE(source_ref_id, sentinel))`. A recurring type that always passed `source_ref_id: nil` would collide with itself forever after day one — Postgres collapses repeated NULLs to the same coalesced value. `DeterministicCandidateRef` solves this without touching the Phase 2A index: it derives a stable UUID from `(user_id, source_type, bucket)`, where `bucket` is a calendar day (`daily_pearl`, `oite_question`) or a 14-day window (`first_try`). Same user + same type + same bucket → same UUID → the existing unique index does its job; a new bucket → a new UUID → a fresh row is allowed.

There's also an app-level pre-check (`existingCandidateWithinCooldown`) that queries for an existing candidate of the same `notification_type` within the cooldown window before attempting the insert — this lets dry-run report accurate "would skip, already scheduled" counts without needing to provoke a DB constraint violation to find out.

---

## Audience selection (exactly as implemented)

Base eligibility (must pass before any type is considered):
- At least one `user_device_tokens` row with `invalidated_at IS NULL`, `receive_notifications = true`, `environment = $APNS_ENVIRONMENT`, `user_id IS NOT NULL`.
- A `user_profiles` row exists for that `user_id` (read-only raw SQL — see below). No profile → skipped entirely, regardless of type.
- Not in the daily/weekly send cap (`NotificationUserState.sendsToday`/`sendsThisWeek`, checked via the existing `CandidateRanking` pure functions from Phase 2A).
- Not in `is_holdout` (global) or `is_all_growth_holdout`.

Per-type eligibility on top of the above:
- `brobot.first_try`: zero rows in `brobot_conversations` for this user, `brobot` category enabled (preference or default), not `is_brobot_holdout`, no `first_try` candidate created in the last 14 days.
- `learning.oite_question` / `learning.daily_pearl`: `learning` category enabled (preference or default), not `is_learning_holdout`, no candidate of that exact `notification_type` created in the last 24 hours.

### Reading `user_profiles` and `brobot_conversations`

Both tables are owned by other parts of the product (confirmed via the Supabase schema audit in the strategy doc) — this service never writes to them and doesn't model them as Fluent `Model` types. It reads them via raw SQL (`db as? any PostgresDatabase`, `.sql().raw(...)`), the same pattern already used in `routes.swift` for the `donations` table. No migration was added for either table.

---

## Suppression rules implemented

| Rule | Where enforced |
|---|---|
| Max 1/day | `CandidateRanking.canSendRespectingDailyCap` — checked by the generator (skip creating) and the dispatcher (skip sending if somehow still pending) |
| Max 3/week | `CandidateRanking.canSendRespectingWeeklyCap` — same two checkpoints |
| `brobot.first_try` max once per 14 days | `DeterministicCandidateRef.multiDayBucketKey(days: 14)` + the cooldown pre-check |
| `learning.daily_pearl` / `learning.oite_question` max once per day | `DeterministicCandidateRef.dayBucketKey` + the cooldown pre-check |
| No product/conversion content | Not implemented in this phase at all — `GenerateLearningCandidatesCommand` only ever produces the 3 types above; nothing in this phase touches `NotificationCategory.product` |

### Holdout — three flags, deliberately not auto-assigned

`NotificationUserState` (Phase 2A) had one `is_holdout` boolean: a random, permanent, ~8%-of-users measurement holdout. Phase 2B adds three more, **all defaulting to `false` for everyone**:

- `is_learning_holdout` — suppresses `learning` candidates for this user
- `is_brobot_holdout` — suppresses `brobot` candidates for this user
- `is_all_growth_holdout` — suppresses every Phase 2B candidate type for this user

**These are not randomly assigned.** The spec didn't ask for a percentage, and inventing one unprompted would be overreach — these are intended as operator/future-admin-controlled flags for excluding a specific user or cohort from one growth surface without pulling them out of the original measurement holdout. Flip them directly in Supabase for now; a future phase could add an admin endpoint.

### Preferences

Both learning and brobot candidate types check `notification_preferences` for the relevant category before creating anything, falling back to `NotificationCategory.defaultEnabled` (`true` for both `learning` and `brobot`) when no preference row exists yet — same pattern Phase 1's `NotificationService` already uses.

---

## Commands

### `seed-notification-templates`
```bash
swift run SnapOrthoBackend seed-notification-templates
```
No flags. Idempotent. Safe to run anytime, including repeatedly.

### `generate-learning-candidates`
```bash
# Dry run (default) — reports counts, writes nothing
swift run SnapOrthoBackend generate-learning-candidates

# Commit, capped at 100 users
swift run SnapOrthoBackend generate-learning-candidates --commit --limit 100

# Test against your own account first
swift run SnapOrthoBackend generate-learning-candidates --user-id <your-uuid> --dry-run
swift run SnapOrthoBackend generate-learning-candidates --user-id <your-uuid> --commit
```
- Default is dry-run. `--commit` is required to write.
- `--limit` caps the number of *users evaluated* (and therefore candidates created, since at most one candidate is created per user).
- `--user-id` restricts to a single user — still runs through every eligibility/cooldown/cap check for real, so it's a genuine pipeline test, not a bypass.
- Logs aggregate counts only (`evaluated`, `created`/`wouldCreate`, a breakdown of skip reasons, a `byType` count). Never logs a raw device token, a raw user id is logged but that's not a secret (it's already the join key across every table in this system) and never a PHI-bearing field.

### `process-scheduled-notifications` (the missing Phase 2A piece, added now)
```bash
swift run SnapOrthoBackend process-scheduled-notifications
swift run SnapOrthoBackend process-scheduled-notifications --limit 10
```
- Fetches up to `--limit` (default 50) candidates where `status=pending`, `eligible_at <= now`, `expires_at > now`.
- Groups by user; for any user with more than one due candidate, picks the highest-priority one via `CandidateRanking.selectTop` (Phase 2A infra, now actually exercised) and marks the rest `superseded`.
- Re-checks daily/weekly caps and holdouts via `NotificationUserState` immediately before sending — if blocked, marks the candidate(s) `cooldown_blocked` rather than sending.
- Sends via the existing `NotificationService.sendToUser` (Phase 1) — which independently re-checks category preferences and handles token invalidation, so this command inherits all of that for free.
- Marks the sent candidate `status=sent` and increments `NotificationUserState.sendsToday`/`sendsThisWeek`.
- Runs once and exits. Does **not** touch the Phase 2A lifecycle scheduler (`CandidateSchedulerJob`), which keeps ticking every 15 minutes exactly as before — it still only counts pending rows and resets day/week buckets. Dispatch stays a deliberate, manually-triggered action in this phase.

---

## Production rollout checklist (as specified)

1. `swift run SnapOrthoBackend seed-notification-templates`
2. `swift run SnapOrthoBackend generate-learning-candidates --dry-run` — review the aggregate counts
3. `swift run SnapOrthoBackend generate-learning-candidates --user-id <your-uuid> --commit` — create exactly one candidate for yourself
4. Verify the row: `SELECT * FROM notification_candidates WHERE user_id = '<your-uuid>'`
5. `swift run SnapOrthoBackend process-scheduled-notifications` — **only sends if `eligible_at` has already passed** (it'll be next-morning by default, so either wait or manually move `eligible_at` back for this one test row)
6. Check `notification_delivery_attempts` for a row matching that send
7. Only after that round-trip works end to end, consider a larger `--limit` batch

## Rollback plan

- Stop using `generate-learning-candidates --commit` and `process-scheduled-notifications` — both are manually invoked, not wired into the always-on lifecycle job, so simply not running them halts all Phase 2B activity immediately.
- Any already-`pending` candidates can be neutralized without code changes: `UPDATE notification_candidates SET status = 'expired' WHERE status = 'pending'`.
- The two new migrations (`AddNotificationTypeToCandidates`, `AddGranularHoldoutColumns`) are additive ALTERs — reverting them (`notification_type` column, the three holdout columns) is safe and won't affect Phase 1/2A data.
- No changes were made to `user_profiles`, `brobot_conversations`, or any other pre-existing product table — nothing to roll back there.

---

## Analytics — "design but do not overbuild"

No new table. The minimum events requested (candidate created / skipped / processed) are currently:
- Structured log lines at each decision point in `LearningCandidateGenerator` and `ProcessScheduledNotificationsCommand` (e.g. `📊 Learning candidate generation ... byType=...`, `✅ User ... sent ...`, `🚫 ... blocked — daily/weekly cap reached`).
- The `source` tag (`first_brobot_try` / `daily_pearl` / `oite_question`) is embedded directly in each candidate's `payload`, so it's queryable from `notification_candidates` itself without a separate events table.
- "Notification opened" is already handled by the existing `notification_interactions` table (Phase 2A) and its associated endpoint — untouched here.

Promoting this to a real analytics events table is a reasonable Phase 2C+ task if/when dashboarding becomes a priority — not built now, per the explicit instruction not to overbuild this.

---

## Test Results

19 new tests in `NotificationPhase2BTests.swift`, covering every item on the requested list: dry-run/commit/idempotency, token/profile/holdout/preference eligibility gates, first_try-vs-learning priority (all three branches), daily cap suppression, `--limit` and `--user-id` behavior, template seeding idempotency, command registration, and an end-to-end dispatch-and-verify-delivery-attempt test.

**Build status:** `swift build`, `swift build -c release`, and `swift build --build-tests` all succeed with zero errors. No new warnings beyond pre-existing ones unrelated to this phase.

**Live test run:** executed `swift test --filter NotificationPhase2BTests` against real credentials from `.env.local`. **All 19 tests failed — and all 19 failed for the identical reason**, confirmed by inspecting every failure line:

```
database-id=psql [AsyncKit] Opening new connection for pool failed: PSQLError(code: connectionError, underlying: Connect timeout (10 s))
```

This is the **Amazon RDS** connection (`.psql`), not Supabase — note `✅ Supabase notifications DB configured` printed successfully in every single test before the Amazon timeout. `configure(app)` requires both databases to connect before any test body runs (Amazon migrations and Supabase migrations both go through one `app.autoMigrate()` call), so every test — including ones that need zero Amazon RDS access, like the command-registration check — fails at that shared gate before reaching its own logic.

This is the exact same environmental limitation documented in the Phase 2A and Phase 1 verification turns, re-confirmed here rather than assumed. It is not a Phase 2B regression: the test target compiles cleanly, and the failure occurs identically whether the test needs zero, one, or many database operations, which is only consistent with a shared precondition failing, not per-test logic. I did not modify `configure()`'s connection requirements to route around this — that would change production boot behavior to suit a sandbox limitation.

**What this means concretely:** the 19 new tests are well-formed and ready to run, but none of them have actually exercised the new code against a live database in this session. Re-run `swift test --filter NotificationPhase2BTests` from an environment with real Amazon RDS access before merging.

---

## Recommended Phase 2C prompt

```
Implement Phase 2C of the SnapOrtho notification system: BroBot conversation follow-up
candidates (24-hour and 72-hour), now that Phase 2B's learning + first-BroBot-try candidates
have been running in production for [N] weeks.

Context:
- Phase 2A shipped notification_candidates, notification_templates, notification_interactions,
  notification_user_state, plus CandidateRanking (priority/cooldown/cap pure functions) and
  HoldoutAssignment (deterministic global holdout).
- Phase 2B shipped LearningCandidateGenerator (learning.daily_pearl, learning.oite_question,
  brobot.first_try), GenerateLearningCandidatesCommand (dry-run by default, --commit required),
  ProcessScheduledNotificationsCommand (the dispatcher — picks the top candidate per user via
  CandidateRanking, sends via NotificationService, marks losers superseded), and
  SeedNotificationTemplatesCommand. Also added: notification_candidates.notification_type
  column, three operator-set holdout flags (is_learning_holdout/is_brobot_holdout/
  is_all_growth_holdout) alongside Phase 2A's random is_holdout, and DeterministicCandidateRef
  (solves the NULL-uniqueness problem for recurring candidate types — reuse this for any new
  recurring type rather than re-deriving the fix).
- BroBot's real schema (audited live in BROBOT_LEARNING_NOTIFICATION_STRATEGY.md): 
  brobot_conversations (id, user_id, last_mode, created_at, updated_at), brobot_messages
  (conversation_id, user_id, role, content, mode, created_at), brobot_message_tags (message_id,
  user_id, topic, subtopic, body_region, procedure, concept_type, mode) — topic tagging already
  exists and is populated, no new instrumentation needed for basic topic-based follow-up copy.
- brobot_first_try (Phase 2B) already nudges users with zero BroBot conversations toward
  trying it. Phase 2C's job is the next step: following up with users who HAVE used BroBot,
  to bring them back.
- CandidateSourceType already has brobotFollowup24h (priority 90) and brobotRecall72h
  (priority 70) defined in CandidateRanking.swift from Phase 2A — unused until now. Use them
  as-is rather than adding new source types unless the priority ordering genuinely needs to
  change.

Phase 2C scope:
1. Add a BrobotFollowUpCandidateGenerator service, parallel in structure to
   LearningCandidateGenerator: reads brobot_conversations (read-only raw SQL, same pattern as
   Phase 2B's user_profiles/brobot_conversations reads — do not add a Fluent model or migration
   for tables this service doesn't own).
2. 24-hour follow-up: brobot_conversations.updated_at between 22-26 hours old, brobot category
   eligible (preference + not is_brobot_holdout + not is_holdout/is_all_growth_holdout), no
   brobot_followup_24h candidate already created for that exact conversation_id (use
   source_ref_id = the real conversation_id this time, not a DeterministicCandidateRef bucket —
   each conversation only ever gets one 24h follow-up, ever, so the existing
   UNIQUE(user_id, source_type, source_ref_id) constraint from Phase 2A is sufficient as-is).
3. 72-hour recall: same conversation, 70-76 hours old, only if the 24h follow-up for that
   conversation was never opened (check notification_interactions joined through
   notification_delivery_attempts — if Phase 2B's interaction tracking isn't being populated
   yet because the iOS app doesn't call the interaction endpoint, treat "never opened" as
   "no interaction row exists," which degrades gracefully to "always eligible" until the app
   wires up open tracking).
4. Copy: pull the most common brobot_message_tags.topic value for that conversation's messages
   and template it into the existing daily_pearl-style templates pattern — add two new
   notification_templates rows (brobot.followup_24h, brobot.recall_72h) via an extension to
   SeedNotificationTemplatesCommand, with {{topic}} as a literal placeholder Phase 2C should
   implement simple substitution for (this is the first template requiring variable
   substitution — Phase 2A/2B templates were all static strings).
5. Reuse the existing 12-hour brobot-category cooldown and 48-hour same-source-type cooldown
   from CandidateRanking.isBlockedByCooldown — don't add new cooldown logic, wire the existing
   pure functions in.
6. Add a --commit-gated generate-brobot-followup-candidates command, same dry-run-by-default
   shape as generate-learning-candidates, with the same --limit and --user-id flags.
7. Tests: 24h window boundary (22h/26h edges), 72h fires only when 24h wasn't opened, topic
   extraction from message tags, template variable substitution, cooldown reuse correctness.

Constraints:
- Do not implement abandoned-conversation recovery yet (separate detection logic, defer).
- Do not implement conversion/subscription nudges yet (that's Phase 2D).
- Do not modify brobot_conversations, brobot_messages, or brobot_message_tags — read-only.
- Reuse CandidateRanking and DeterministicCandidateRef from Phase 2A/2B rather than duplicating
  logic — if something doesn't fit, extend those shared files rather than forking new ones.
- All code must compile and existing tests must continue passing.
```
