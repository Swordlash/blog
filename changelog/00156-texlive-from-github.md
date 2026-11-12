---
pr: 156
title: TeX Live's installer and Perl's source from GitHub
technical: true
---

## New features

- The deploy clones TeX Live's installer and Perl's source from their
  GitHub mirrors, which proxies that refuse CTAN's and CPAN's downloads
  let through. `--texlive-installer` and `--perl-source` name another
  repository, or a directory on the machine that holds them already:

  ```sh
  sh toolchain/deploy-local.sh --server --texlive \
    --texlive-installer /srv/mirrors/install-tl \
    --perl-source https://git.example.org/perl5
  ```
