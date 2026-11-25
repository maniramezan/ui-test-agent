# Swipe to delete a task

- Platforms: ios, android
- Backends: real, moq
- Sign-in: user@example.com

## Steps

1. Sign in.
2. Swipe the newest task to the left and tap Delete.

## Expected

- The list shows every task before the swipe, and one fewer after it.
- The deleted task is gone from the list.
- With mocks: the list request carried a bearer token for user-1 and the session cookie, exactly one
  `DELETE /v1/tasks/{id}` was sent after the swipe, and no request was refused or unmatched.
