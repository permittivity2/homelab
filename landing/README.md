# www.mailmasker.org, the landing page

The static page at https://www.mailmasker.org/ (the apex mailmasker.org 301s to
www on the host), served by nginx on prod-homelab45 from `/var/www/mailmasker/`
(vhost `mailmasker`). Hand-made in post-cutover #10, a Search link in #46;
#95 (2026-11-18) brought it into this repo and replaced the row of site links
in its header with the app launcher.

- `site/` is the web root, file for file. `index.html` is the page;
  `css/style.css` is a verbatim copy of the silverlinings.llc stylesheet (do
  not edit it here, re-sync it); `css/mailmasker.css` holds this page's
  overrides and the launcher's rules; `images/` has the logo, the favicon and
  `bimi-logo.svg`, which mailmasker.org's BIMI record points at (never move or
  rename it).
- **The launcher** is the same markup, icons and six sites as homelab-webtheme's
  header (`webtheme/templates/homelab/header.html.ep`, the `@default_sites` and
  `%ICON` in `webtheme/lib/Homelab/WebTheme.pm`), copied by hand: the page is
  static and does not load the theme stylesheet, so the rules live in
  `mailmasker.css` in the page's own variables. Its behaviour is the theme's
  `shell.js` from static.mailmasker.org (one script for every launcher). When
  the theme's site list changes, change the tiles here too; the deploy script's
  `--verify` compares the two lists. Without script a plain row of the six links
  shows instead (`<noscript>`).
- **Deploy:** `install-orchestrators/landing-deploy.sh` (`--dry-run` shows what
  differs; a plain run pushes the files that differ, each with a dated backup
  beside it on the host, and never deletes anything there; `--verify` checks the
  live files are this directory's, the page and its pieces answer from offsite,
  the apex redirects, the BIMI logo answers, and the tiles match the theme's
  sites).
