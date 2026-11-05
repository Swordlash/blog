---
pr: 157
title: A deploy that checks its TeX once and does not hang
---

## Bug fixes

- A server deploy checks its TeX once, on the service's PATH, instead of
  twice, so it waits at most 20 seconds for an engine that hangs.
- The deploy no longer hangs after "cloning TeX Live's installer" when an
  earlier installation was interrupted: the installer can no longer wait
  for an answer nobody sees.
- When the CTAN mirror cannot be reached, the deploy says which mirror
  answered or failed, and that `--texlive-mirror` names one this machine
  can reach; the server then runs without PDFs.
