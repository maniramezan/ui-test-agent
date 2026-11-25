# Show only done tasks

- Platforms: ios, android
- Backends: real, moq
- Sign-in: user@example.com

## Steps

1. Sign in.
2. Open the filter and choose Done.

## Expected

- The filter sheet closes and the list says the Done filter is on.
- Only done tasks are counted.
- With mocks: the list was asked for once more, signed in, with `status=done`, and no request was
  refused for an illegal query value.
