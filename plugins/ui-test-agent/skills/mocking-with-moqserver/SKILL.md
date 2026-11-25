---
name: mocking-with-moqserver
description: Get and shape mock data for UI tests with moqserver: build a bundle from an OpenAPI spec, a recorded HAR or the app's code, add failure and filter variants, and check what the app sent (headers, query, claims) from amoo flows. Use when a UI test case runs against a mock server instead of the real backend, or when a mocked flow needs a new response or request check.
---

# Mock data and request checks with moqserver

moqserver serves a **bundle** (`*.moqproj`): endpoints, each with named **variants** (responses) and
rules for what a request must carry. Each test run gets its own **session**, so runs in parallel
don't see each other. Edit bundles with `moq-author`, never by hand; read `moq-author --help` and
moqserver's `docs/NON_GOALS.md` before asking for something it lacks.

## Getting a bundle

Pick the first source the app has:

1. **An OpenAPI spec.** `moq-author project create --path <bundle> --name <name>`, then
   `moq-author import openapi --project <bundle> --source <spec>`. The import maps security schemes
   to auth and cookie rules, names variants after their status (`ok`, `unauthorized`, `notFound`),
   turns `enum`, `minimum`, `maximum` and `pattern` into value rules, and copies a response header
   that has an `example`. Read its `warnings`.
2. **A recording of the real app.** Launch the app with `APITRACE_HAR_FILE=1` (it needs the
   on-device network recorder), run the scenario, pull `apitrace.har` with amoo's
   `device_pull_app_file`, then
   `moq-author import har --project <bundle> --har-path <file> --infer-header-rules`.
3. **The app's code.** Read the networking layer and write each endpoint with
   `moq-author endpoint upsert` and `moq-author variant upsert`.

Never route the app's traffic through moqserver to record it: it has no proxy mode by design.

Then add what a spec can't describe, and validate:

```bash
moq-author variant upsert --project <bundle> --json -     # empty, slow, malformed, serverError, …
moq-author addon enable --project <bundle> --id jwt-claims --config -
moq-author project validate --project <bundle> --strict
```

A variant with `request_match` (for example on a query value) answers only matching requests, which
is how one endpoint returns different lists for different filters. Review the bundle's diff before
committing it in the app's repo.

## Serving it

```bash
moqserver serve --project <bundle> --port <port> --capture-request-headers --capture-request-query
```

Without the two capture flags, header and query checks answer 409.

## In a flow

The `moq.*` steps come from `amoo-ext-moq`; the flow finds the per-app config through `moq_config`.

| Step | Use |
| --- | --- |
| `moq.select_variant {endpoint, variant, times?}` | Answer with another variant; `times: 1` fails just the next call, for retry cases. |
| `moq.mark {name}` | Remember "now", for `since` in later checks. |
| `moq.assert_session_reached {timeout_ms?}` | The app is talking to this run's session. Put it before every other check: on an empty history they all pass. |
| `moq.assert_request {endpoint, times?, headers?, query?, claims?, since?, timeout_ms?}` | What the app sent. `headers`: `{name}` plus one of `present`, `scheme`, `fingerprint_of`, `equals`. `query`: `{name}` plus one of `present`, `equals`, `fingerprint_of`. |
| `moq.assert_no_rejected_requests` | No request broke an auth, cookie or value rule. |
| `moq.assert_no_unmatched_requests` | No request missed the bundle. |
| `moq.assert_all_requests_carry_session` | No request left the session. |

`endpoint` is `METHOD /path` as `moq-author endpoint list` shows it; `uita lint --bundle` checks
every key. A check never compares a credential's value: use `fingerprint_of`.

Prefer checking the request over checking the screen when the bug would be invisible: a dropped
header that a retry papers over, or a filter the app shows but doesn't send.

## What mocks are not for

A case about real server behaviour (an account disabled mid-session, data that must persist) belongs
on the real backend, with `auth.*` steps and a backend session. A mock only proves what the app does
with the answer you scripted.
