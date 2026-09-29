# Vendored front-end libraries

Third-party JS shipped verbatim and served locally (never from a CDN —
the app must work self-contained on bare CT hosts with no internet).

- **cytoscape.min.js** — Cytoscape.js 3.30.2, MIT licensed
  (https://js.cytoscape.org). Used by the admin Topology tab to render the
  fleet graph. The MIT license text is in the file's own header comment.
  To update: fetch dist/cytoscape.min.js for the desired version and drop
  it in here (keep the version pinned in this note).
