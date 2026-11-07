---
pr: 184
title: Your password no longer leaves your browser
---

## New features

Signing in with a password, and setting one, now goes through OPAQUE: your
browser proves to the server that it knows your password without sending
it. The server keeps a record made from your password, never the password
itself or a hash of it, so neither the server nor anyone who reads the
traffic can learn it or test guesses against what it stores. This works
over plain HTTP too, and nothing changes in the forms: you type your login
and password as before.

Signing in, and setting a password, take about half a second longer than
before, because your browser now does the slow part of protecting the
password itself. The first time you do either, your browser also fetches
the part of the wiki that does it (about 160 KB).

An account made before this moves over by itself the next time you sign in:
that one time your password is sent as before, and from then on never
again. Until every account has moved, a wrong password typed at the sign-in
form is also sent once, as it always was. The administration's Overview
shows how many accounts have still to move ("Old passwords").

The server's console sets passwords the same way:

```sh
wiki users password ada --data ~/wiki-demo/data
```

## Other changes

The rules for a new password (at least eight characters) are now checked by
your browser, since the server never sees the password.
