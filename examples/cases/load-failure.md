# The task list fails to load once

- Platforms: ios, android
- Backends: moq
- Sign-in: user@example.com

## Steps

1. The first request for the task list answers 500.
2. Sign in.
3. Tap Try Again.

## Expected

- The list says the server had a problem and offers Try Again.
- After Try Again the tasks are listed.
- The list was asked for exactly twice.
