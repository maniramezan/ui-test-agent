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
| **ui-test-agent** (this repo) | `amoo-ext-moq`, `amoo-ext-auth`, `uita`, the per-app config format, the agent + skills plugin, the eval | Yes: uses both, through their CLIs and public APIs only |
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
   - Codegen: emit `MoqClient` calls for XCUITest (Swift) and for Espresso and Compose (Kotlin); names and
     predicates match moqserver's clients exactly.
   - The wire contract with amoo is amoo's `docs/flow-extensions.md` (protocol 1, amoo `2579744`): verbs
     `describe`, `flow_start`, `step`, `flow_end`, one JSON request on stdin and one reply on stdout. `describe` lists
     only implemented steps, so a flow using an unbuilt one fails before step 1.
   - `emit` (amoo `508021a`) is built for all three frameworks. For XCUITest, `amoo generate test`
     gets `import MoqTestSupport`, a `moqSession` member with a `moq()` accessor, setup lines that open one session per
     test and set the config's launch keys on `app`, a teardown line that closes it, and one `MoqClient` call per
     step. A `moq.mark` becomes a local (`before-delete` → `moqMarkBeforeDelete`) that later `since` arguments
     name. `assert_session_reached` becomes `assertRequest(timeout:)` with no endpoint, which passes once any
     request reached the session (moqserver `d9ba477`). The config is found as `flow_start` finds it: through the
     flow variable `moq_config`, which amoo sends with `emit` from `7c425ac`, then `AMOO_EXT_MOQ_CONFIG`. The
     generated test reads `MOQ_PORT` at run time (`TEST_RUNNER_MOQ_PORT=<port> xcodebuild test`), defaulting to
     the config's port. The test target depends on moqserver's `MoqTestSupport` product, pinned by repository
     URL and commit (moqserver `79234c0`).
   - For Espresso and Compose the same calls come out in Kotlin (`com.moqserver.testsupport.MoqClient`, from
     JitPack as `com.github.ArjangConsulting:moqserver:<10-character sha>`). The setup opens the session on the
     Android platform's `appHost`, which is where both the app and the test reach the server from a device,
     and reads the port from the instrumentation argument `MOQ_PORT`
     (`am instrument -e MOQ_PORT <port>`, or
     `-Pandroid.testInstrumentationRunnerArguments.MOQ_PORT=<port>` with Gradle).
     amoo's generated Kotlin test builds the launch intent itself from the flow's literal environment, so the
     per-test launch keys are added by an `ActivityLifecycleCallback` at `Stage.PRE_ON_CREATE`, just before
     the activity's `onCreate` reads its intent. That works because instrumented tests run in the app's
     process. Kotlin needs no `requires`: the client's calls block, and a JUnit test can't suspend.
   - moqserver's request assertions are frozen (server `6b6c130`, clients `5b2ecf7`): `POST /_admin/requests/query`,
     `POST /_admin/requests/mark`, and `times` on the variant route. Specs: its `docs/ADMIN_API.md` ("Request
     queries"), `server/MoqTestSupport/README.md` and `clients/kotlin/README.md`.
   - Built: the four protocol verbs; attach (wait on the config's readiness path), one session per run, launch keys
     returned as `launch_environment` plus `${moq_session}`; all nine steps. Starting moqserver is not built; the
     app's own serve script does that. `session start|end` and `config check` remain for use outside amoo.
   - Each request check sends the same query body as the `MoqClient` call of the same name, so a flow step and a
     generated test get the same verdict from the server. Keep it that way: never evaluate a predicate in the bridge.
     `assert_no_unmatched_requests` sends `{"unmatched": true, "times": 0}`, which needs moqserver `8091415` or later.
   - At flow start the bridge reads moqserver's capabilities (`GET /_admin/version`, moqserver `748fae4`; a 404
     means none) and keeps them in the run state. `mark` and the `assert_*` steps need `request-query`;
     `select_variant` with `times` needs `limited-overrides`. A step whose capability is missing fails with the
     name, without calling the server, so an old server can't pass a check by matching nothing. Check
     capabilities, never the version: source builds report `version` and `commit` as null. moqserver's
     `docs/NON_GOALS.md` lists what it won't do; read it before asking for a server feature.
   - Step arguments (snake_case; numbers and booleans may be strings after `${…}` substitution; unknown arguments
     fail the step):
     - `select_variant {endpoint, variant, operation?, times?}`, where `times` makes a one-shot override.
     - `mark {name}` stores the server time in the run state.
     - `assert_request {endpoint, times?, headers?, query?, claims?, since?, timeout_ms?}`. Each `headers` item is
       `{name}` plus exactly one of `present` (bool), `scheme`, `fingerprint_of` or `equals`, one-to-one with
       `MoqHeaderExpectation`. Each `query` item is `{name}` plus exactly one of `present` (bool), `equals` or
       `fingerprint_of`, one-to-one with `MoqQueryExpectation`; names are case-sensitive. `query` needs the
       capability `request-query-parameters` (moqserver `d9ba477`) and a server started with
       `--capture-request-query`; without capture the server answers 409 and the step fails with its reason.
       A failed check lists near misses with the query that was sent.
     - `assert_no_rejected_requests {since?}`.
     - `assert_all_requests_carry_session {claims?, include_unattributed?, since?}`.
     - `assert_session_reached {timeout_ms?}` passes once any request reaches this run's session; put it right after
       the app's launch. A launch without the session key sends the app to its real backend, and every other check
       would then pass on an empty history. It sends an unfiltered query (`{}`), as `MoqClient.assertRequest()` with
       no endpoint does.
     - `since` is a mark name or Unix seconds on the server clock.
   - `endpoint` is a moqserver endpoint key as `GET /_admin/endpoints` lists it. From moqserver `543bd37` a
     trailing-slash difference resolves, and an unknown key answers 400 with the closest key, which fails the
     step, so a `times: 0` check can't pass on a typo. Older servers silently match nothing.
   - Flows should set amoo's `"terminate_app_at_end": true` (amoo `638c4b8`): an app left running keeps sending its
     released session id, and other runs' session checks on a shared server would see it. A flow with no `moq.*`
     step declares `"extensions": ["moq"]` to get a session; vars alone don't start the extension.
   - Just before releasing the session, `flow_end` writes `<output_dir>/moq-session.json`:
     `{schema, session, requests, unmatched, rejected, app_terminated, apps_launched}`. The counts come from the
     same query bodies the steps send; a failed query leaves its count `null`. From amoo `d38b415`, `flow_end`'s
     message prints as a note and `ok: false` as a teardown warning; neither changes pass/fail. The bridge warns
     when the run launched an app (`apps_launched`, amoo `686317a`) and no request reached the session, and notes
     an app left running only when one was launched. A check that should fail the run belongs in a step
     (`assert_session_reached`).
   - Flows find the config through the flow variable `moq_config` (or `AMOO_EXT_MOQ_CONFIG`) and the port through
     `moq_port` (or `MOQ_PORT`). Relative paths resolve against amoo's working directory.
2. **`amoo-ext-auth`** (Swift executable): account fixtures for `auth.*` steps. Two providers sit behind the same
   steps: the Firebase Auth emulator (`firebase-emulator`), and the app backend's own test routes (`test-routes`).
   - Steps, each `{email}`: `auth.disable_user`, `auth.enable_user`, `auth.delete_user`, `auth.revoke_tokens`.
     An unknown email fails the step.
   - Prerequisite, for the `firebase-emulator` provider only: a running Firebase Auth emulator, which comes with the Firebase CLI
     (`brew install firebase-cli` or `npm install -g firebase-tools`; needs Node.js), started with
     `firebase emulators:start --only auth --project <projectId>`. `flow_start`'s failure message gives both
     commands. moqserver neither includes nor calls the emulator: its `jwt-claims` add-on only decodes the token
     the app sends. An app that doesn't sign in through Firebase uses `test-routes`.
   - The per-app config gains `"auth": {"provider": "firebase-emulator", "host": "127.0.0.1:9099",
     "projectId": "demo-example"}`. `host` is how this Mac reaches the emulator and falls back to
     `FIREBASE_AUTH_EMULATOR_HOST`; a Google host is refused, so these steps never touch a real project. The flow
     finds the config through the var `auth_config`, then `moq_config`, then `AMOO_EXT_AUTH_CONFIG`. `flow_start`
     fails if the emulator doesn't answer.
   - `flow_end` puts back every account a step changed, as the run first found it: re-enables or re-disables it, or
     recreates a deleted one with its id, fields and password (the emulator keeps the password readable in its
     fake hash). A revocation can't be undone; the next run signs in fresh.
   - Emulator differences, checked against firebase-tools 15.18.0: after `revoke_tokens`, ID tokens issued earlier
     fail, but the emulator still exchanges an old refresh token, unlike production. After `disable_user`, both
     sign-in and refresh fail with `USER_DISABLED`.
   - It calls the emulator's admin routes (`accounts:lookup`, `update`, `delete`, `batchCreate`) with the
     emulator's `owner` token. Shared protocol types live in `Sources/ExtensionKit`, which `MoqBridge` re-exports.
   - **`test-routes`** calls routes the backend offers for tests, for an app run against its real backend
     (`examples/moq.json` shows the section):
     `"auth": {"provider": "test-routes", "baseURL": "http://127.0.0.1:8081", "sessionHeader": "X-Test-Session",
     "launchEnvironment": {"APP_TEST_SESSION": "{{sessionId}}"}, "routes": {"release": {"method": "DELETE",
     "path": "/_test/sessions/{session}"}, "disable_user": {"method": "PUT", "path":
     "/_test/accounts/{email}/disabled"}, …}}`.
     - `routes` maps a step name to `{method, path}`; `{email}` and `{session}` are percent-encoded into the
       path. A step with no route fails by name, and so does a route that doesn't answer 2xx. `baseURL` must be
       loopback: these routes change data, so they are never called on another machine.
     - With `sessionHeader`, `flow_start` makes an id for the run, sends it in that header on every route call
       and returns `launchEnvironment` (`{{sessionId}}`, `{{baseURL}}`) for amoo to merge into app launches. A
       backend that keeps one data set per id then lets real-backend runs go in parallel, as moqserver sessions
       do for mocked ones. `flow_end` calls the `release` route; a 404 there means nothing reached the session.
       A flow with no `auth.*` step declares `"extensions": ["auth"]` to get a session.
     - Without `sessionHeader` the run shares the backend's data, and `flow_end` undoes the first change to each
       account with the opposite route (`disable_user` ↔ `enable_user`); other steps can't be undone.
     - `emit` is built for this provider, in Swift for XCUITest and Kotlin for Espresso and Compose: a
       per-test `authSession` id, the launch keys, a `release` call in teardown that never fails the test, and
       `authExpect("<METHOD>", "<path>")` per step. The helpers call the backend with blocking calls, since
       neither a JUnit test nor amoo's Kotlin setup can suspend. The config is found through the flow variables
       `auth_config` and `moq_config`, then `AMOO_EXT_AUTH_CONFIG`. In Kotlin the launch keys reach the app the
       way the moq extension's do, and `baseURL`'s loopback host becomes `10.0.2.2`, the development machine
       as an Android emulator reaches it. The `firebase-emulator` provider answers `ok: false`.
3. **Per-app config**, a JSON file kept in the app's repo (`examples/moq.json` shows the format): how to start or
   attach moqserver, admin auth by reference, launch-env keys for base URL and session, sign-in profile, id catalog
   and test target locations. Today it holds the server (port, admin host, readiness path, admin auth by env var
   name) and per-platform launch keys; values may use `{{baseURL}}` (built from the platform's `appHost`, e.g.
   `10.0.2.2` on an Android emulator) and `{{sessionId}}`. Add the other fields with the steps that use them.
4. **The agent and lean skills**, packaged as a plugin. Discovery once; anything repeatable becomes an amoo flow that
   runs on the CLI at no model cost.
   - The plugin is `plugins/ui-test-agent/` (version `0.1.0`), listed by `.claude-plugin/marketplace.json` at the
     repo root. Check both with `claude plugin validate plugins/ui-test-agent` and `claude plugin validate .`.
   - `agents/ui-test-agent.md`: takes one case (the fields of `examples/cases/<case>.md`), an app repo, a
     platform and a backend, and returns only a JSON report: the flow, the generated test, bundle changes,
     lint and repeat counts, the generated test's result per device, and findings. It writes flows, generated
     tests and the mock bundle, never app source.
   - `skills/writing-ui-tests`: case → flow → `uita lint` → `uita repeat` → `amoo generate` → run in parallel.
     `skills/mocking-with-moqserver`: a bundle from a spec, a recording or code, variants, and the `moq.*`
     checks. `skills/onboarding-an-app`: what an app and its repo need before the first flow.
   - Keep the skills to what a run needs and what was verified on the example; when a rule here changes (a
     step's arguments, a tool's flag), change the skill in the same commit.
   - Not built: running the agent against the example's cases as an eval (piece 5).

   Two mock-data paths:
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
5. **Eval**: run the agent on the first targets and compare against doing them by hand (tokens, wall time, pass rate).
6. **`uita`** (Swift executable over the `UitaKit` library): what the agent, or a person, runs around amoo with no
   model cost. It works on any flow, mocked or not.
   - `uita lint <flow>… [--bundle <bundle.moqproj>] [--moq-author <command>] [--json]` checks flows without a
     device. Errors exit 1; warnings don't. Run it from the directory amoo runs in. Rules:
     - `terminate-app-at-end`: an app is launched and not ended (error with a mock session, else warning).
     - `session-reached`: a mocked flow that launches an app has no `moq.assert_session_reached` (error), or runs
       a request check before it (warning).
     - `extension-not-started`: `moq_config`, `moq_port` or `auth_config` is set, but no step or `extensions`
       entry starts that extension.
     - `config-missing`: a config variable's path doesn't exist.
     - `undefined-mark`: `since` names no earlier `moq.mark`.
     - `unknown-endpoint` (with `--bundle`): an `endpoint` isn't in the bundle, read with
       `moq-author endpoint list`; the message gives the closest key.
     - `tap-outcome` (warning): a `tap_element` has no `expect_*` and the next step doesn't observe anything.
     Add a rule when a mistake has cost a run; each one names what goes wrong, not a style.
   - `uita repeat <flow> (--runs <n> | --failure-rate <p>) --output-dir <dir> [--runtime-id <id>]… [--amoo
     <command>] [--json] [-- <amoo flow arguments>]` runs the flow n times with `amoo flow`, one worker per
     runtime id in parallel, each run in `<dir>/run-NNN` with amoo's output in `amoo.log`. `--failure-rate`
     works the count out: n ≥ ln(0.05) / ln(1 − p), at least 10 (0.2 → 14, 0.1 → 29). The summary gives the
     pass rate, flow times, the failure rate the passes rule out, and failures grouped by step, tool and amoo's
     `failure_kind`, never by message text. It also lists runs whose `moq-session.json` shows unmatched or
     refused requests. Exits 1 unless every run passed.
   - Not built yet: coverage, triage and the request renderer.

## Commands

```bash
swift build
swift test --parallel
swift test --filter SessionLifecycleTests
swift test --filter AuthHandlerTests
.build/debug/amoo-ext-moq config check --config examples/moq.json
(cd examples && ../.build/debug/uita lint flows/ios/*.amoo.json --bundle mocks/example.moqproj)
(cd examples && ../.build/debug/uita repeat flows/ios/swipe-delete.moq.amoo.json --failure-rate 0.2 \
  --runtime-id <id-1> --runtime-id <id-2> --output-dir <dir> -- --var moq_port=<port>)
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

## The example

`examples/` is the public end-to-end target: one API (`openapi.yaml`), a real local backend (`server/`), a mock
bundle (`mocks/example.moqproj`), an id catalog (`ids.json`), flows (`flows/<platform>/`) and app implementations
side by side under `apps/`. Each case exists as a pair: `<case>.real.amoo.json` runs against the backend with no
mocks, `<case>.moq.amoo.json` against a moqserver session with request checks.

```bash
swift build --package-path examples/server
examples/server/.build/debug/example-server --port 8081
moqserver serve --project examples/mocks/example.moqproj --port <port> --capture-request-headers \
  --capture-request-query

cd examples/apps/android && ./gradlew :app:assembleDebug :app:assembleDebugAndroidTest

cd examples/apps/ios && xcodegen generate
xcodebuild build -project ExampleApp.xcodeproj -scheme ExampleApp -derivedDataPath build \
  -destination 'platform=iOS Simulator,id=<udid>'

cd examples
export AMOO_EXTENSION_PATH=$PWD/../.build/debug
amoo flow flows/ios/swipe-delete.real.amoo.json --device <udid> --port <amoo-port> --runtime-id <id> --output-dir <dir>
amoo flow flows/ios/swipe-delete.moq.amoo.json \
  --device <udid> --port <amoo-port> --runtime-id <id> --output-dir <dir> --var moq_port=<port>
```

- The backend keeps its data in memory, one seeded data set per `X-Test-Session` value plus a shared one for
  requests without the header. A real-backend flow gets its own session from `amoo-ext-auth` (`test-routes`
  provider) and the app joins it through `APP_TEST_SESSION`, so real-backend runs are as independent as mocked
  ones and both kinds run in parallel. `POST /_test/reset` puts a data set's seed back, and
  `DELETE /_test/sessions/<id>` drops one.
- `mocks/example.moqproj` is `moq-author import openapi` of `openapi.yaml` (moqserver `7f0d309` or later, which
  maps the bearer-plus-cookie security, copies a response header that has an `example`, names variants after
  their status (`ok`, `unauthorized`, `notFound`) and turns the query parameters' `enum`, `minimum` and
  `maximum` into value rules), then `moq-author addon enable --id jwt-claims`, plus the variants a spec can't
  describe: `openOnly` and `doneOnly` matched on the `status` query, `empty`, `slow`, `malformed`, `serverError`
  and `serviceUnavailable`.
- `cases/<case>.md` is a case as a developer, or their agent, hands it over: a title, `Platforms`, `Backends`
  (`real`, `moq` or both), `Sign-in`, numbered `Steps` in plain language and `Expected` results. The flows and
  generated tests of the same name are what the agent makes of it.
- `apps/android/` is the same app in Kotlin and Compose, with the same ids as test tags published as resource
  ids (`testTagsAsResourceId`; a dialog or bottom sheet is its own window and sets it again). Launch keys arrive
  as intent extras, and the development machine is `10.0.2.2`, so its flows in `flows/android/` set
  `base_url` to `http://10.0.2.2:8081`. Its two differences from iOS are platform habits: a swipe deletes the
  row outright, and an alert's buttons are reported once. The app targets API 36 on purpose: Android 17 keeps
  an app that targets 37 off local-network addresses, which include `10.0.2.2`, until a permission is granted,
  and every request then times out.
- `apps/android/app/src/androidTest/kotlin/` holds the Compose tests amoo generated from `flows/android/`,
  unedited (`amoo generate test --ui-toolkit compose`). Install both APKs and run them on each device in
  parallel; name the devices, since `connectedAndroidTest` would also use emulators that belong to someone else:

  ```bash
  adb -s <serial> install -r app/build/outputs/apk/debug/app-debug.apk
  adb -s <serial> install -r app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk
  adb -s <serial> shell am instrument -w -e MOQ_PORT <port> \
    com.example.app.test/androidx.test.runner.AndroidJUnitRunner
  ```
- Cases so far, each as a flow and a generated test on both platforms: `swipe-delete` (real, moq), `filter` (real, moq: the query
  string is checked by the bundle's value rules and by `query` on `moq.assert_request`), `delete-all` (real, moq: Edit, the
  confirmation alert, the empty state), `account-disabled` (real: `auth.disable_user` mid-session) and
  `load-failure` (moq: a one-shot 500, then Try Again).
- iOS reports each button of a SwiftUI alert twice, with the same id. A tap on one names its pick
  (`"first": true`). A tap that should bring the alert up states its outcome as the alert's text
  (`expect_contains_text`), not as a button's id: the flow accepts two matches of an `expect_id`, but the
  generated test's check for it needs exactly one. Let an alert settle (`wait_for` with `idle: true`) before
  tapping it.
- An accessibility identifier on a container such as `ContentUnavailableView` lands on every child, so a
  selector for it matches several elements. The app combines the container into one element first
  (`.accessibilityElement(children: .combine)`).
- `apps/ios/UITests/` holds the XCUITests amoo generated from the flows, unedited. Regenerate one with
  `amoo generate plan --from-flow <flow> --out <dir>`, then
  `amoo generate test --plan <dir>/plan.json --test-name <Name> --out apps/ios/UITests`, run from `examples/`
  with `AMOO_EXTENSION_PATH` set; the extensions find `moq.json` through the flow's own variables. amoo doesn't
  overwrite a generated file, so delete the old one first. The target takes moqserver's `MoqTestSupport`
  product by repository URL, pinned to a commit until moqserver tags releases.

  ```bash
  TEST_RUNNER_MOQ_PORT=<port> xcodebuild test -project ExampleApp.xcodeproj -scheme ExampleApp \
    -derivedDataPath build \
    -destination 'platform=iOS Simulator,id=<udid-1>' -destination 'platform=iOS Simulator,id=<udid-2>' \
    -destination 'platform=iOS Simulator,id=<udid-3>' \
    -parallel-testing-enabled YES -parallel-testing-worker-count 3
  ```

  Both servers must be running: the mocked tests use moqserver, the others the backend on port 8081.
- **"Save Password?" on iOS simulators.** Once an XCUITest has typed into a password field on a simulator, iOS
  offers to save the password after every sign-in there, for amoo flows too. On iOS 27.2 the sheet is outside
  the app's element tree: the tree shrinks to the application element, the failed step names no dialog, and
  amoo's `dismiss_system_dialogs` has nothing to press (from amoo `17577fa` the failure carries
  `only_root_element: true`). Turn password AutoFill off on each simulator used for sign-in tests:
  `amoo env up --platform ios --disable-password-autofill` (amoo `17577fa`) does it before the simulator boots
  and reports `device.password_autofill`; a simulator that is already running is left alone, with the
  `xcrun simctl shutdown` to run first. The setting stays on the simulator. It is the
  `restrictedBool.allowPasswordAutoFill` value in the simulator's `UserSettings.plist`.

  The first sign-in after the change may still show the sheet once. Measured on the example: with AutoFill on,
  0 of 3 flow runs passed after a fresh boot; with it off, 18 of 19, and the generated tests passed on three
  simulators in parallel.

## Conventions

- Confirm a new convention (tag notation, first version, commit style, config file names) with the user before
  creating it. Bare SemVer, no `v` prefix, once versions exist.
- Never end a line of code with a comment; put it on its own line above.
- Commit straight to `main` unless the user asks otherwise.
