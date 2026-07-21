# SnapOrtho notification runbook

## Required production configuration

Set `SUPABASE_DATABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `ADMIN_API_KEY`,
`APNS_KEY_PATH`, `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_BUNDLE_ID`, and
`APNS_ENVIRONMENT`. `APNS_ENVIRONMENT` is exactly `production` or `sandbox`;
`APNS_BUNDLE_ID` must be `com.alexbaur.Snap-Ortho` for the current app target.
The `.p8` key must exist inside the runtime container at `APNS_KEY_PATH`.

Never put secret values, raw device tokens, authorization headers, or notification
content containing PHI in logs or tickets.

## Exact-device smoke test

1. Install a signed build on a physical device and confirm the embedded
   `aps-environment` entitlement. Development builds register as `sandbox`;
   TestFlight/App Store builds register as `production`.
2. Sign in, grant notifications, and confirm the backend records one active row
   with the expected user, environment, `receive_notifications=true`, and a
   masked token-hash identifier.
3. Confirm the running backend has the same `APNS_ENVIRONMENT` and the expected
   `APNS_BUNDLE_ID`. A single backend process intentionally serves one APNs
   environment.
4. POST `/admin/notifications/test` with `X-Admin-Key` and an exact 64-character
   device token plus explicit `environment`. Use only synthetic copy:
   `SnapOrtho Test` / `Notification delivery is working.`
5. Require `target_count=1` in the pre-send log. Stop if the target is inactive,
   opted out, invalidated, or its environment differs from the server.
6. Check `notification_delivery_attempts`. An application HTTP 200 means only
   that the backend completed the send path. Confirm APNs acceptance separately
   from device display/receipt.

## Diagnostics

- `BadDeviceToken` or `Unregistered`: the row is invalidated and must not be retried.
- `DeviceTokenNotForTopic`: verify bundle ID and signed app topic before retrying.
- `ExpiredProviderToken`, `InvalidProviderToken`, or
  `TooManyProviderTokenUpdates`: verify team/key IDs, key material, and provider
  token lifecycle; do not invalidate the device.
- `TopicDisallowed`: verify the key and app identifier capabilities.
- `PayloadTooLarge`: reduce custom metadata; do not invalidate the device.
- Rate limit, timeout, and network failures are transient; do not invalidate.

## Scheduled delivery

`CandidateSchedulerJob` maintains candidate state but does not dispatch pending
rows. Candidate generation and `process-scheduled-notifications` are currently
operator-invoked commands. Verify command execution logs and candidate/delivery
row counts before enabling any external scheduler. Never test scheduling through
the broadcast route.

## Deployment and rollback

Record the deployed Git SHA in the release system, run the health endpoint, and
inspect startup logs for successful notification database and APNs configuration.
Rollback by redeploying the previous known-good image/SHA. Do not roll back schema
by dropping notification tables; the current repair requires no migration.
