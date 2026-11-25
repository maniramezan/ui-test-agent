# Delete all tasks

- Platforms: ios, android
- Backends: real, moq
- Sign-in: user@example.com

## Steps

1. Sign in.
2. Tap Edit, then Delete All.
3. Confirm in the alert.

## Expected

- Delete All asks before deleting: an alert says it can't be undone.
- After confirming, the list is empty and says so.
- With mocks: exactly one `DELETE /v1/tasks` was sent, after the confirmation.
