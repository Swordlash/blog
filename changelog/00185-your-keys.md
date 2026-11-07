---
pr: 185
title: Your keys, for encrypted spaces
---

## New features

Every user now has a key pair, which encrypted spaces will use to share
their keys with you. It is made in your browser the first time you sign in
with your password, and its secret half is sealed in your vault, where the
server keeps it without being able to open it. Signing in with your
password on another device unlocks it there.

Your account's security has a new section, **Keys**. It shows your key's
fingerprint, for example:

```
3F2A 9C1B 07D4 E8A6 …
```

so that someone you share a space with can check, by comparing it with
what their wiki shows, that the server gave them your key. It also shows
whether this browser holds your keys, what unlocks them (your passkeys,
and your password if you chose it), and lets you unlock them with a
passkey or your password, add or remove your password as a way to unlock,
and have the wiki ask each time it opens.

If your keys sync the writing assistant's settings with a passkey already,
the wiki asks you once, after you sign in with your password, whether your
password should unlock them too. The answer is no unless you say yes: with
your password among them, your keys are only as safe as your password.

Changing your password keeps your keys. A password reset keeps them if a
passkey of yours unlocks them; otherwise it deletes them, with the
assistant's synced settings and API keys, and the reset page says so before
you set the new password.

## Other changes

The writing assistant's vault is now your vault, holding its settings
beside your key pair. Nothing changes in how the assistant's keys sync. A
tab still open from before this version keeps working, and changes nothing
but the assistant's settings.
