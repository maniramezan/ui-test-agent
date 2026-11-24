# ui-test-agent

A UI test agent for iOS and Android apps, built on [amoo](https://github.com/maniramezan/mobile-testing) and [moqserver](https://github.com/maniramezan/moqserver). See [AGENTS.md](AGENTS.md) for the plan and how the repos split the work.

## What you need

| For | Tool | Get it |
| --- | --- | --- |
| Every flow | amoo | `brew install arjangconsulting/tap/amoo` |
| `moq.*` steps | moqserver, and `moq-author` to build a mock bundle | Release archives; see moqserver's README, "Install And Update" |
| `auth.*` steps only | Firebase Auth emulator, part of the Firebase CLI (needs Node.js) | `brew install firebase-cli` or `npm install -g firebase-tools`, then `firebase emulators:start --only auth --project <projectId>` |

moqserver and the Firebase Auth emulator are separate programs with separate jobs. The emulator is the identity
provider: it holds the test accounts and issues their tokens, and `auth.*` steps change those accounts through
its admin routes. moqserver is the app's mocked API: it only reads the token the app sends, to pick a response
by claim and to record who made each call. Neither talks to the other, and an app that doesn't sign in through
Firebase needs no emulator.

## Status

Early design. The first piece, `amoo-ext-moq`, lets `amoo flow` open an isolated moqserver session per run and drive it with `moq.*` steps. A second, `amoo-ext-auth`, adds `auth.*` steps that disable, delete or revoke accounts on a Firebase Auth emulator and put them back at flow end. Build both with `swift build`; `examples/moq.json` shows the per-app config an app keeps in its own repo.
