---
pr: 151
title: The assistant's key tested before it is kept, and its services
---

## New features

- The writing assistant's settings test a key before they keep it. "Test
  and keep the key" asks the provider for its models with the key you
  typed, then sends a short message with the chosen model. A key that
  works is kept; one that does not is not, and the reason is shown by the
  field, so you can pick another model and try again.
- An administrator lists the services the assistant may use besides
  Anthropic's and OpenAI's own, in the Server section: a name, a base
  URL and the API it speaks. Writers then choose one under "Service" in
  their assistant's settings, with no address to type:

  ```text
  Name:      Corporate gateway
  Base URL:  https://claude-gateway.example.com/v1
  API:       Anthropic
  ```

- Choosing a new avatar opens its crop in a window over the page, with
  the picture fitted whole and the largest square inside it chosen to
  start with.
