# ui-test-agent

A UI test agent for iOS and Android apps, built on [amoo](https://github.com/maniramezan/mobile-testing) and [moqserver](https://github.com/maniramezan/moqserver). See [AGENTS.md](AGENTS.md) for the plan and how the repos split the work.

Early design. The first piece, `amoo-ext-moq`, lets `amoo flow` open an isolated moqserver session per run and drive it with `moq.*` steps. Build it with `swift build`; `examples/moq.json` shows the per-app config an app keeps in its own repo.
