# ui-test-agent

A UI test agent for iOS and Android apps, built on [amoo](https://github.com/maniramezan/mobile-testing) and [moqserver](https://github.com/maniramezan/moqserver). See [AGENTS.md](AGENTS.md) for the plan and how the repos split the work.

Early design. The first piece, `amoo-ext-moq`, lets `amoo flow` open an isolated moqserver session per run and drive it with `moq.*` steps. A second, `amoo-ext-auth`, adds `auth.*` steps that disable, delete or revoke accounts on a Firebase Auth emulator and put them back at flow end. Build both with `swift build`; `examples/moq.json` shows the per-app config an app keeps in its own repo.
