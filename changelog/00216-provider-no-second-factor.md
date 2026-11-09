---
pr: 216
title: No second factor after signing in with a provider
---

## Other changes

- Signing in with Google, GitHub, Apple or another provider no longer asks
  for your second factor's code. The provider confirms who you are with its
  own sign-in, and its own second factor if you have one there. The wiki's
  second factor protects your password: signing in with your password still
  asks for the code, as before.
- An account without a password can no longer turn a second factor on. Under
  "Second factor" in your account panel, "Set up a second factor…" is greyed
  out, with a line saying why:

  > A second factor protects a password, and you have none: signing in with
  > your provider uses the provider's own.

  If you turned one on before, it stays on until you remove it, and
  "Remove second factor…" still works with a code from your authenticator
  application.
