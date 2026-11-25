# The account is disabled while signed in

- Platforms: ios, android
- Backends: real
- Sign-in: user@example.com

## Steps

1. Sign in.
2. The account is disabled on the backend.
3. Open a task.
4. Try to sign in again.

## Expected

- Opening the task ends the session: the sign-in screen appears and says the account is disabled.
- Signing in again is refused with the same message.
