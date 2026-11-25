---
name: onboarding-an-app
description: Prepare an iOS or Android app's repo for flow-based UI tests with amoo, uita and optionally moqserver: the per-app config, launch keys, an id catalog, the UI test target's dependencies, backend test sessions and simulator or emulator settings. Use once per app, before writing its first flow, or when a flow fails for a setup reason.
---

# Onboarding an app

Everything here lives in the app's own repo. The tools' repos stay generic.

## What the app must do

1. **Read where its backend is at launch.** iOS: launch environment. Android: string extras on the
   launch intent. A base URL key, plus for mocks a mock base URL and a mock session id sent as
   `X-Mock-Session` on every request.
2. **Refuse a half-configured launch.** A mock base URL without a session shows an error screen
   instead of the app. Otherwise the app talks to the mock server outside any session, or to its real
   backend, and every request check passes on an empty history.
3. **Expose stable ids.** iOS: `accessibilityIdentifier`. Compose: `testTag` under a root with
   `testTagsAsResourceId = true`, set again inside each dialog and bottom sheet, which are separate
   windows. One id per element: an id on a container lands on its children, so combine the container
   into one element. Keep a catalog of ids in the repo so flows and reviews share one list.

## The per-app config

One JSON file (the example's `examples/moq.json` shows every field):

- `server`: moqserver's port, admin host, readiness path, admin auth by environment variable name.
- `platforms.ios|android`: `appHost` (the machine as the device reaches it: `127.0.0.1` on a
  simulator, `10.0.2.2` on an Android emulator) and `launchEnvironment` with `{{baseURL}}` and
  `{{sessionId}}`.
- `auth`: for account steps and backend sessions. `test-routes` calls the backend's own test routes
  on this machine; with `sessionHeader` each run gets its own data set. `firebase-emulator` acts on a
  running Firebase Auth emulator.

Check it with `amoo-ext-moq config check --config <file>`.

## A real backend that tests can share

Runs in parallel need separate data. Give the local backend a header that selects a data set seeded
on first use, a route that drops one, and test routes for what a case must arrange (disable an
account). Keep those routes out of the API spec so they never reach a mock bundle, and never expose
them beyond this machine.

## The UI test target

- iOS: add moqserver's `MoqTestSupport` product by repository URL, pinned to a commit until it tags
  releases.
- Android: add `com.github.ArjangConsulting:moqserver:<10-character sha>` from JitPack as
  `androidTestImplementation`, with `androidx.test:runner`, `androidx.test.ext:junit` and, for
  Compose, `ui-test-junit4`.
- Generated tests go in a folder of their own and are committed unedited.

## Devices

- iOS: turn password AutoFill off on simulators used for sign-in
  (`amoo env up --platform ios --disable-password-autofill`). Otherwise a Save Password sheet that
  automation can't see blocks every step after sign-in.
- Android: an app that targets API 37 can't reach `10.0.2.2` on Android 17 until the local-network
  permission is granted; a test build that only talks to the development machine can target 36.
- Use devices no other session is using (`amoo env list`).

## Done when

A flow that launches the app, signs in and asserts the first screen passes `uita lint` and
`uita repeat` on two devices, once against the real backend and, if mocks are used, once against
moqserver.
