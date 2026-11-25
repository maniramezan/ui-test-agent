# ui-test-agent

A UI test agent for iOS and Android apps, built on [amoo](https://github.com/maniramezan/mobile-testing) and [moqserver](https://github.com/maniramezan/moqserver). See [AGENTS.md](AGENTS.md) for the plan and how the repos split the work.

## What you need

| For | Tool | Get it |
| --- | --- | --- |
| Every flow | amoo | `brew install arjangconsulting/tap/amoo` |
| `moq.*` steps | moqserver, and `moq-author` to build a mock bundle | Release archives; see moqserver's README, "Install And Update" |
| `auth.*` steps with the `firebase-emulator` provider only | Firebase Auth emulator, part of the Firebase CLI (needs Node.js) | `brew install firebase-cli` or `npm install -g firebase-tools`, then `firebase emulators:start --only auth --project <projectId>` |

moqserver and the Firebase Auth emulator are separate programs with separate jobs. The emulator is the identity
provider: it holds the test accounts and issues their tokens, and `auth.*` steps change those accounts through
its admin routes. moqserver is the app's mocked API: it only reads the token the app sends, to pick a response
by claim and to record who made each call. Neither talks to the other, and an app that doesn't sign in through
Firebase needs no emulator.

## Install the agent and skills

In Claude Code:

```
/plugin install ui-test-agent --marketplace maniramezan/ui-test-agent
```

This adds the `ui-test-agent` subagent and three skills: `writing-ui-tests`, `mocking-with-moqserver` and
`onboarding-an-app`. They drive the command-line tools this repo builds (`swift build`) and amoo.

## Status

Working on a public example, not yet released. What exists:

- `amoo-ext-moq`: lets `amoo flow` open an isolated moqserver session per run and drive it with `moq.*` steps (variants, marks, checks on what the app sent: headers, query, token claims).
- `amoo-ext-auth`: `auth.*` steps that disable, delete or revoke accounts and put them back at flow end, on a Firebase Auth emulator or through the app backend's own test routes. With test routes it can also give each run its own data set on the backend, so real-backend runs go in parallel.
- Both write the matching test code when amoo generates an XCUITest or a Compose/Espresso test from a flow.
- `uita`: checks flows without a device (`uita lint`) and runs one many times across devices, grouping the failures (`uita repeat`).
- The plugin: the `ui-test-agent` subagent and three skills.
- `examples/`: a fictional tasks app for iOS and Android with its own backend, API spec and mock bundle, eight cases as flows, and the tests generated from them.

Build the tools with `swift build`. [AGENTS.md](AGENTS.md) has the commands, what each piece does, and what's next.

## License

MIT. See [LICENSE](LICENSE).
