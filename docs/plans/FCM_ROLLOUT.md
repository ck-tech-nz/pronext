# FCM Push Notifications — Rollout Plan

**Status**: Phase 1 code complete (awaiting merge+deploy with Phase 2+3); Phase 2 in progress
**Owner**: ck
**Created**: 2026-04-23
**Updated**: 2026-04-23 — Phase 1 validated end-to-end on Android real device; Phase 2 reordered (multi-device first)

## Context

As of 2026-04-23 the Pronext app has FCM **configured in name only**:

- `firebase_messaging` is in [app/pubspec.yaml](../../app/pubspec.yaml) and `FirebaseMessaging.instance.getToken()` is called in `main.dart`, but the token is only `debugPrint`-ed — never sent to backend.
- Backend (`backend/`) has **zero** FCM-related code: no `firebase-admin`, no device-token field, no registration endpoint, no send-push service.
- The old `GoogleService-Info.plist` pointed at a Firebase project `pronext2` that is **inaccessible** to the team's Google account — confirmed during 1.8.0 rejection investigation.

Push notifications therefore have never actually worked for iOS users.

During the 1.8.0 → 1.8.1 resubmit fix (see [`releases/v1.8.1+1090.md`](../releases/) once created) we migrated iOS Firebase config to a new, valid project `pronext-ae7fd` (project number `384914832319`). Android Firebase config still points at the dead `pronext2` and will be migrated in Phase 1 below.

## Goals

1. Users receive push notifications for the events that currently create in-app `Notification` rows (invites, calendar updates, system messages).
2. Same Firebase project serves iOS + Android to simplify backend auth.
3. Tokens are refreshed automatically on app start and on FCM `onTokenRefresh`.
4. Failed sends (expired tokens, unregistered devices) don't crash notification creation or spam the logs.

## Non-goals (explicitly out of scope)

- Rich notifications (images, action buttons) — defer until baseline works.
- Silent data pushes for background sync — a separate design needed.
- APNs-only "delivery receipt" tracking — use Firebase's own delivery metrics.
- Android notification channels beyond a single default channel — polish later.
- Localizing push body strings — English baseline first, i18n later.

## Phase 1 — Prove the wire (target: 1 focused day)

Scope is intentionally minimal so that at the end of Phase 1 we have **proof the full pipe works**: Firebase token reaches backend, backend calls FCM, device gets the notification. No business-logic integration yet.

### App (`app/` — branch `feat/fcm-phase-1`)

1. Register Android app in Firebase project `pronext-ae7fd`:
   - Android package: `com.pronextusa.pronext` (confirm from [android/app/build.gradle.kts](../../app/android/app/build.gradle.kts))
   - Download `google-services.json`, commit to [android/app/google-services.json](../../app/android/app/)
2. Update [lib/firebase_options.dart](../../app/lib/firebase_options.dart) `android` section with the new project values.
3. Verify `android/build.gradle` + `android/app/build.gradle` still apply the `com.google.gms.google-services` plugin correctly.
4. In `main.dart`, wrap the existing `getToken()` so that on success it POSTs to the backend (below). Also register `onTokenRefresh` so rotated tokens get re-uploaded.
5. Call from Flutter:
   ```
   POST /device/register_fcm_token
   body: { "fcm_token": "<token>", "platform": "ios" | "android" }
   auth: Bearer token (existing)
   ```

### Backend (`backend/` — branch `feat/fcm-phase-1`)

1. Add `firebase-admin` to `pyproject.toml` (uv).
2. Add service account JSON:
   - In Firebase Console → `pronext-ae7fd` → Project Settings → Service accounts → Generate new private key.
   - Store as env var `FIREBASE_CREDENTIALS_JSON` (full JSON blob) or `FIREBASE_CREDENTIALS_FILE` (path).
   - Load in Django via `firebase_admin.initialize_app(credentials.Certificate(...))` in an `AppConfig.ready()` hook.
3. Migration: add `fcm_token`, `fcm_platform`, `fcm_updated_at` to the existing `Device` model (or wherever the authenticated device record lives — confirm path).
4. New endpoint `POST /device/register_fcm_token` — takes JSON body, updates current user's active device row, returns 204.
5. New service `pronext.notifications.push.send_to_device(device, title, body, data)` — thin wrapper around `firebase_admin.messaging.send`. Handle `UnregisteredError` → clear `fcm_token` on the device row. Log everything at INFO.
6. Django admin action on `Device`: "Send test push" — calls the service with canned strings.

### Testing

- App debug build on iPhone + Android, inspect logs for token upload 200.
- Django admin "Send test push" → both devices get a banner within seconds.
- Uninstall one app → "Send test push" again → backend logs `UnregisteredError` and the token is cleared, no exception.

### Phase 1 exit criteria

- ✅ Tokens persist on the backend (ended up on `Profile` for Phase 1, migrated
      to `UserAppDevice` in Phase 2 — see below).
- ✅ Admin-triggered test push reaches the device (validated on Android real
      device; iOS simulator cannot receive real FCM pushes by Xcode design, so
      iOS delivery verification is deferred to iOS real-device testing later).
- ✅ Uninstalled-device send is handled gracefully (`UnregisteredError` →
      token cleared, no exception).
- ⏳ **Merge + prod deploy + one prod test push** — deferred: per release
      philosophy we ship only the complete feature, so main merge and prod
      deploy happen after Phase 2 + 3 are done.

## Phase 2 — Multi-device support + hook into notification business flow

**Order reordered 2026-04-23**: multi-device support (originally item #3) moved
to the first step. Rationale: once Phase 1's single-token-per-user design meets
real business events (items 3–4 below), a parent logged in on iPhone + Android
would silently receive push on only one of them. Fixing this after wiring
business events would create a window where users experience broken delivery.
Fixing it first means users never see the broken state.

1. **Multi-device support** (in progress): new `pronext.user.UserAppDevice`
   model keyed on (user, install_id). App-side `install_id` is a UUID
   generated once per install and persisted in secure storage; it survives
   FCM token rotation but resets on app reinstall. `register_fcm_token`
   upserts by (user, install_id). Account switch on a shared install drops
   the previous user's row. `push.send_to_user(user_id, ...)` iterates all
   of a user's registered installs; per-device errors (UnregisteredError,
   invalid token) delete only the failing row, never sibling devices.
2. Data migration: Phase 1 left `Profile.fcm_token` / `fcm_platform` /
   `fcm_updated_at`. Phase 2's first commit removes those fields outright
   since Phase 1 hasn't shipped to main and the schema hasn't reached any
   customer DB; no data migration needed.
3. Identify every backend code path that creates a `Notification` row
   (calendar invites, shared calendar updates, system announcements,
   etc. — audit first).
4. Add `push.send_to_user(user_id, ...)` call after each creation.
   **Gate on `Notification.if_push` — push is one delivery channel alongside
   inbox/email/sms; don't fire if `if_push` is False.**
5. Deduplication: if the user is actively in the app (foreground WebSocket
   or very recent heartbeat), suppress the push — we don't need to buzz a
   user who just saw the banner in-app.
6. Retry policy: Firebase retries internally on transient; our code retries
   only on explicit rate-limit signals with jittered backoff.
7. Metrics: log per-send to an internal table or Prometheus counter — which
   notifications go through, how many fail, broken down by platform.

## Phase 3 — Polish

- Android notification channel with sound/vibration overrides.
- iOS category actions (e.g. Accept/Decline from the notification for invites).
- Localization.
- Silent-push protocol for background calendar sync nudge (separate design doc).

## Risks / known unknowns

- **APNs sandbox vs. prod**: [Runner.entitlements](../../app/ios/Runner/Runner.entitlements) currently declares `aps-environment = development`. For App Store builds this **must** be `production` or pushes silently drop. Needs a separate entitlements variant per configuration (or leave "development" and rely on the App Store signing flip-flop — confirm with Apple docs).
- **Google account access to `pronext2`**: the old Android Firebase config still points there. If Android users have existing FCM tokens on pronext2 stored anywhere, they'll be orphaned after migration. Confirm: is `pronext2` live under another team Google account? If yes, we may want to keep Android on pronext2 and re-plan. For now the assumption is pronext2 is dead and fresh tokens on pronext-ae7fd are correct.
- **Backend deploy coupling**: device-registration endpoint ships before app code that calls it — harmless (nothing uses the field yet). App code that calls the endpoint ships before backend supports it — 404 is caught silently, no user impact. Either order is safe.

## References

- Firebase Console: https://console.firebase.google.com/u/0/project/pronext-ae7fd
- `firebase_messaging` (Flutter): https://pub.dev/packages/firebase_messaging
- `firebase-admin` (Python): https://firebase.google.com/docs/admin/setup#python
- iOS APNs setup (Apple): https://developer.apple.com/documentation/usernotifications
