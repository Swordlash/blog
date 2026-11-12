---
pr: 210
title: Faster, more visible deploys, and a rehearsal that passes with personal spaces
technical: true
---

## Other changes

The first deploy on a machine builds the maker, the program that does the
rest of the deploy, with its libraries. That took minutes with nothing on
the screen. The deploy now shows cabal's progress as it builds them, as it
already did for the wiki's own build:

```sh
sh toolchain/deploy-local.sh   # "Building library for …", then the maker's modules
```

A deploy that builds the page itself compiled the application's library
twice on the same machine: once without optimisation for the page's
prerender, and again with it for the server. The prerender is now built
with the server's build, so the library is compiled once.

The upgrade rehearsal stopped a deploy with an error such as

```
GET …/admin/api/v1/spaces/2c5f9160-…/pages answered 404
```

on a wiki with personal spaces. The rehearsal reads every page of every
space before and after the upgrade, and some spaces in the list are ones
nobody may read, administrators included: the space that holds the
personal spaces, and a personal space its owner has hidden. The rehearsal
now leaves those out, so such a deploy goes through without
`--no-rehearsal`.
