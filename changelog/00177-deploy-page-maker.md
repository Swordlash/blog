---
pr: 177
title: The deploy takes the page CI built in the maker
---

## Other changes

A deploy that takes the page CI built, from GitHub with `--backend-only`
or from a file with `--app-page`, now downloads it, keeps it in the page
cache and unpacks it in the maker. What it prints and keeps in the
cache is the same as before. One thing moves: the page is looked up
after the toolchain is installed or checked, not before. A REF that has
no page on GitHub still stops the deploy before anything is built:

    sh toolchain/deploy-local.sh --server --backend-only=main

Reading GitHub's answers no longer needs python3 or jq. Unpacking the
page still needs python3, or unzip.
