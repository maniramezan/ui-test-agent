---
name: writing-ui-tests
description: Turn a UI test case for an iOS or Android app into an amoo flow that passes repeatedly and the XCUITest or Compose/Espresso test generated from it, using uita lint, uita repeat and amoo generate. Use when asked to write, automate or generate a UI test from steps and expected results, with or without a mock server.
---

# From a case to a flow and a generated test

A **flow** (`*.amoo.json`) is the step list `amoo flow` runs on a device. A **generated test** is the
XCUITest or Compose/Espresso code `amoo generate test` writes from that flow. Write the flow, make it
stable, then generate; never hand-write the test.

Work in the app's repo. Its per-app config (the example calls it `moq.json`) says how flows reach the
backend or the mock server. If there is none, use the `onboarding-an-app` skill first. For a mocked
case, also load `mocking-with-moqserver`.

## 1. Read before touching a device

- The case: steps and expected results. Each expected result becomes a step that can fail.
- The app's code for the screens involved: accessibility ids (or the id catalog), control types,
  alerts and sheets, what each action requests from the backend.
- A sibling flow for the same app, when one exists: copy its launch and sign-in steps.

## 2. Write the flow

- Launch with `device_launch_app`; set `"terminate_app_at_end": true`.
- Real backend: declare `"extensions": ["auth"]` and `auth_config`, so the run gets its own data set
  on a backend that supports sessions. Mocked: set `moq_config`, and `moq_port` on the command line.
- Select by accessibility id. Use visible text only for system-owned controls.
- Every tap states its outcome (`expect_id`, `expect_contains_text`, `expect_absent: true` for
  something that should close) or is followed by an assertion.
- A dialog, alert or sheet: `wait_for` with `idle: true` before tapping inside it.
- iOS reports each alert button twice: pick with `"first": true`.
- Mocked: put `moq.assert_session_reached` after the app's first request and before any other
  request check; end with `moq.assert_no_rejected_requests`, `moq.assert_no_unmatched_requests` and
  `moq.assert_all_requests_carry_session`. Check what a step sent with `moq.assert_request`
  (`headers`, `query`, `claims`, `since` a `moq.mark`).

## 3. Check it without a device

```bash
uita lint <flow> [--bundle <bundle.moqproj>]
```

Fix every error. A warning needs a reason to stay.

## 4. Make it pass, then prove it is stable

```bash
amoo env up --platform ios --device <udid> --app <build> --app-id <id> --disable-password-autofill --json
uita repeat <flow> --failure-rate 0.2 --runtime-id <id> [--runtime-id <id2>] --output-dir <dir> \
  [-- --var moq_port=<port>]
amoo env down --runtime-id <id>
```

`--failure-rate 0.2` runs 14 times; use 0.1 (29 runs) for a flow that will gate merges. Several
`--runtime-id` values run in parallel. Read the summary: failures are grouped by step, tool and
failure kind. Open one failing run's `report.json` and screenshot, fix the cause, and repeat the
whole count. Do not add sleeps or retries to hide a failure.

What a failure usually means:

| Seen | Likely cause |
| --- | --- |
| A selector matches several elements | An id on a container that lands on its children, or an alert's doubled buttons. Fix the app's id, or name the match. |
| The tree shows only the app element | A system sheet is in front (Save Password). Turn AutoFill off on the simulator. |
| A request check finds 0 | The action didn't reach the app, the endpoint key is wrong, or the server isn't capturing headers or query. |
| Every request times out on Android | The app targets API 37 and is kept off local-network addresses. |
| Passes alone, fails in parallel | Runs share data. Use a mock session or a backend session per run. |

## 5. Generate the test and run it

```bash
amoo generate plan --from-flow <flow> --out <dir>
amoo generate test --plan <dir>/plan.json --test-name <Name> --out <test-dir> [--ui-toolkit compose]
```

Run from the directory the flow's config path is relative to, with `AMOO_EXTENSION_PATH` pointing
at `amoo-ext-moq` and `amoo-ext-auth`. amoo doesn't overwrite a file: delete the old one first.
Commit the generated file unedited; if it needs a change, change the flow and regenerate.

Run the generated tests in parallel on several devices, never one:

```bash
TEST_RUNNER_MOQ_PORT=<port> xcodebuild test -scheme <Scheme> \
  -destination 'platform=iOS Simulator,id=<a>' -destination 'platform=iOS Simulator,id=<b>' \
  -parallel-testing-enabled YES -parallel-testing-worker-count 2

adb -s <serial> shell am instrument -w -e MOQ_PORT <port> <test-package>/androidx.test.runner.AndroidJUnitRunner
```

On Android, name each device; a bare `connectedAndroidTest` also runs on emulators that belong to
someone else.

## 6. Report

Say what was written, the lint result, the repeat counts, the generated test's result per device,
and each finding with its evidence path. A flow that passed once is not done; neither is a generated
test that compiled but did not run.
