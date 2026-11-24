# ui-test-agent

A UI test agent for iOS and Android apps, plus the bridge that lets [amoo](https://github.com/maniramezan/mobile-testing)
flows drive a [moqserver](https://github.com/maniramezan/moqserver) mock server. Given a feature or screen, the agent
reads the app's code, gets mock data, drives the app with amoo against an isolated moqserver session, asserts UI state,
requests and accessibility, and leaves a checked-in flow, a generated test, bundle changes and a compact JSON report.

This file is the shared instruction set for any coding agent working in this repo.

## Where things live

| Repo | Owns | Knows about the others? |
| --- | --- | --- |
| [amoo](https://github.com/maniramezan/mobile-testing) | Device driving, flows, test generation, a general external-step hook (`prefix.step` → `amoo-ext-<prefix>`) | No |
| [moqserver](https://github.com/maniramezan/moqserver) | Mock server, admin API, `MoqClient` (Swift, Kotlin), `moq-author` | No |
| **ui-test-agent** (this repo) | `amoo-ext-moq`, the per-app config format, the agent + skills plugin, the eval | Yes: uses both, through their CLIs and public APIs only |
| Each app under test | Its own per-app config, mock bundle, flows and tests | Uses this repo's tools |

Rules that follow from this:

- Never vendor or copy amoo or moqserver code or docs here. Call their CLIs and read their `--help`.
- When this repo needs something from amoo or moqserver, ask that tool's owner for a feature framed as a general
  capability that helps the tool's standalone users too, not as a ui-test-agent special case. Each tool designs and
  ships it on its own terms; this repo adopts it once it lands.
- **This repo is public and generic.** Never put an app's name, its config, mock data, flows, findings, local paths
  or the names of agent sessions here, in code, docs, tests, examples or commit messages. App-specific material lives
  in the app's own repo. Examples and tests use the fictional app in `examples/`.
- App teams bring their gaps in amoo or moqserver here, or go straight to the owning tool.

## Planned pieces

1. **`amoo-ext-moq`** (Swift executable). amoo calls it for `moq.*` flow steps and for their generated test code:
   - Steps: `moq.activate_scenario`, `moq.select_variant`, `moq.reset_variant`, `moq.mark`, `moq.assert_request`,
     `moq.assert_no_rejected_requests`, `moq.assert_no_unmatched_requests`, `moq.assert_all_requests_carry_session`.
   - Lifecycle: at flow start, attach to or start moqserver and create an isolated session (`POST /_admin/sessions`),
     returning launch-env keys amoo merges into app launches; release the session at flow end.
   - Codegen: emit `MoqClient` calls for XCUITest and Espresso/Compose; names and predicates match moqserver's
     clients exactly.
   - The wire contract with amoo is amoo's `docs/flow-extensions.md` (protocol 1, amoo `2579744`): verbs
     `describe`, `flow_start`, `step`, `flow_end`, one JSON request on stdin and one reply on stdout. `describe` lists
     only implemented steps, so a flow using an unbuilt one fails before step 1. A planned `emit` verb drives codegen.
   - moqserver's request assertions are frozen (server `6b6c130`, clients `5b2ecf7`): `POST /_admin/requests/query`,
     `POST /_admin/requests/mark`, and `times` on the variant route. Specs: its `docs/ADMIN_API.md` ("Request
     queries"), `server/MoqTestSupport/README.md` and `clients/kotlin/README.md`.
   - Built: the four protocol verbs; attach (wait on the config's readiness path), one session per run, launch keys
     returned as `launch_environment` plus `${moq_session}`; all nine steps. Starting moqserver is not built; the
     app's own serve script does that. `session start|end` and `config check` remain for use outside amoo.
   - Each request check sends the same query body as the `MoqClient` call of the same name, so a flow step and a
     generated test get the same verdict from the server. Keep it that way: never evaluate a predicate in the bridge.
     `assert_no_unmatched_requests` sends `{"unmatched": true, "times": 0}`, which needs moqserver `8091415` or later.
   - Step arguments (snake_case; numbers and booleans may be strings after `${…}` substitution; unknown arguments
     fail the step):
     - `select_variant {endpoint, variant, operation?, times?}`, where `times` makes a one-shot override.
     - `mark {name}` stores the server time in the run state.
     - `assert_request {endpoint, times?, headers?, claims?, since?, timeout_ms?}`. Each `headers` item is
       `{name}` plus exactly one of `present` (bool), `scheme`, `fingerprint_of` or `equals`, one-to-one with
       `MoqHeaderExpectation`.
     - `assert_no_rejected_requests {since?}`.
     - `assert_all_requests_carry_session {claims?, include_unattributed?, since?}`.
     - `assert_session_reached {timeout_ms?}` passes once any request reaches this run's session; put it right after
       the app's launch. A launch without the session key sends the app to its real backend, and every other check
       would then pass on an empty history. It sends an unfiltered query (`{}`), which has no `MoqClient` helper yet.
     - `since` is a mark name or Unix seconds on the server clock.
   - `endpoint` is a moqserver endpoint key as `GET /_admin/endpoints` lists it. From moqserver `543bd37` a
     trailing-slash difference resolves, and an unknown key answers 400 with the closest key, which fails the
     step, so a `times: 0` check can't pass on a typo. Older servers silently match nothing.
   - Flows should set amoo's `"terminate_app_at_end": true` (amoo `638c4b8`): an app left running keeps sending its
     released session id, and other runs' session checks on a shared server would see it. A flow with no `moq.*`
     step declares `"extensions": ["moq"]` to get a session; vars alone don't start the extension.
   - amoo drops `flow_end`'s reply message and only logs a `flow_end` failure, so the bridge can't warn or fail
     there. Instead, just before releasing the session it writes `<output_dir>/moq-session.json`:
     `{schema, session, requests, unmatched, rejected, app_terminated}`. The counts come from the same query bodies
     the steps send; a failed query leaves its count `null`. The bridge records and never judges: `app_terminated:
     false` means both "launched no app" and "left an app running", and a pure `moq.*` flow legitimately has
     `requests: 0`.
   - Flows find the config through the flow variable `moq_config` (or `AMOO_EXT_MOQ_CONFIG`) and the port through
     `moq_port` (or `MOQ_PORT`). Relative paths resolve against amoo's working directory.
2. **Per-app config**, a JSON file kept in the app's repo (`examples/moq.json` shows the format): how to start or
   attach moqserver, admin auth by reference, launch-env keys for base URL and session, sign-in profile, id catalog
   and test target locations. Today it holds the server (port, admin host, readiness path, admin auth by env var
   name) and per-platform launch keys; values may use `{{baseURL}}` (built from the platform's `appHost`, e.g.
   `10.0.2.2` on an Android emulator) and `{{sessionId}}`. Add the other fields with the steps that use them.
3. **The agent and lean skills**, packaged as a plugin. Discovery once; anything repeatable becomes an amoo flow that
   runs on the CLI at no model cost. Two mock-data paths:
   - Synthesize from the app's code or an OpenAPI spec with `moq-author`.
   - Record real traffic on the device with [mobile-network-recorder](https://github.com/arjangconsulting/mobile-network-recorder)
     (its `ios` and `android` submodules are the platform libraries), export a HAR, and import it with
     `moq-author import har`. The loop runs without app-specific export code:
     1. Launch with `APITRACE_HAR_FILE=1` (in `start_session`'s `environment`, `K=V,K2=V2`). On Android the app
        also calls `APITraceHarFile.enableFromLaunchIntent(application)` once at startup. The recorder rewrites
        `apitrace.har` after each exchange.
     2. Run the scenario, then pull the file with amoo's `device_pull_app_file` (amoo `83ece1b`):
        iOS `{"app_id": "com.example.app", "path": "tmp/apitrace.har", "timeout_ms": "5000"}`;
        Android `{"app_id": "com.example.app", "container": "external", "path": "cache/apitrace.har",
        "timeout_ms": "5000"}`. It lands in the flow's `--output-dir`.
     3. `moq-author import har --project <bundle> --har-path <output-dir>/apitrace.har --infer-header-rules`,
        then review the bundle diff before committing it in the app's repo.
   - moqserver has no record or pass-through (proxy) mode, by the user's decision, and this repo doesn't propose
     one. Recording belongs in the app, where it sees exactly what the app sends; moqserver stays "not a recorder".
4. **Eval**: run the agent on the first targets and compare against doing them by hand (tokens, wall time, pass rate).

## Commands

```bash
swift build
swift test --parallel
swift test --filter SessionLifecycleTests
.build/debug/amoo-ext-moq config check --config examples/moq.json
.build/debug/amoo-ext-moq session start --config <app-repo>/moq.json --platform android --port <port>
.build/debug/amoo-ext-moq session end --config <app-repo>/moq.json --session <sessionId> --port <port>
```

In an amoo flow, point amoo at the local build and give the flow `moq_config` and `moq_port` vars:

```bash
AMOO_EXTENSION_PATH=$PWD/.build/debug amoo flow <flow.amoo.json> --output-dir <dir>
```

A flow made only of `moq.*` steps needs no device, which makes it the quickest end-to-end check. Run it against
`moqserver serve --project <bundle> --port <port> --capture-request-headers` on a spare port. Header capture needs
moqserver `2957465` or later; an older build exits with "Unknown option". Logs go to the unified log under
subsystem `UITestAgent`, so stdout stays JSON only.

## Conventions

- Confirm a new convention (tag notation, first version, commit style, config file names) with the user before
  creating it. Bare SemVer, no `v` prefix, once versions exist.
- Never end a line of code with a comment; put it on its own line above.
- Commit straight to `main` unless the user asks otherwise.
