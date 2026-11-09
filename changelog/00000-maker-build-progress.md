---
pr: 0
title: The deploy shows the maker's build, and compiles the app's library once
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
