# The API reference

What developer.mailmasker.org shows, one YAML file per area. The
homelab-developer package builds the site from these files (see
`../README.md`) and writes each ability's cURL, Perl and homelab-cli
examples from its fields, so nobody writes those by hand. Every ability
is published, admin ones included, each saying who may use it; routes
only fleet services call (`who: fleet`) are left out.

**A new route needs an entry here, or the build fails.** `t/reference.t`
reads every route reachable through the api out of the repo, and checks
four things. Every route has exactly one entry. Every entry is a real
route. Each entry's `who` matches the route's own access check. The
examples hold no real token or address. Run it with:

    cd developer && prove -I lib t/reference.t
    REFERENCE_FILES=drive.yml prove -I lib t/reference.t   # one area

**homelab-cli comes second.** An API call homelab-cli makes is documented
here first, then homelab-cli changes. `cli/tests/test_reference.py`, which
homelab-cli's own build runs, fails on any call in
`cli/homelab_cli/client.py` that has no entry here, and on any `cli:`
command here that homelab-cli's real argument parser doesn't accept.

## A file

```yaml
area: Your addresses and blocking   # the menu heading
order: 40                           # where the area sits in the menu
intro: >                            # optional, a sentence or two
  ...
abilities:
  - id: unblock-address              # lowercase-and-hyphens, unique, used in the page link
    title: Unblock an address        # plain words, a verb first
    method: DELETE                   # GET POST PUT PATCH DELETE
    path: /api/v1/domains/recipient-access/mine/:recipient   # the PUBLIC path, :name for each placeholder
    who: signed-in                   # see below
    status: 200                      # optional; the success status when it isn't 200 (e.g. 201)
    summary: One line for the menu and the top of the page.
    description: >
      A short paragraph: what it does, and anything surprising.
    params:                          # optional
      - name: recipient
        in: path                     # path, query or body
        required: true
        about: What it means, in plain words.
        example: shop@{domain}       # an example value (string, number, true/false, list, object)
    body: |                          # optional: a raw JSON body, for nested bodies params can't express
      { "items": [ { "id": 1 } ] }
    response: |                      # an example answer, as JSON (or plain text for a file)
      { "ok": true }
    notes:                           # optional sentences: limits, side effects, errors worth knowing
      - An address that isn't on your list answers 404.
    cli: homelab-cli mail unblock shop@{domain}   # or: none
    curl: |                          # optional, rare: see "Written examples" below
      curl -s ...
    perl: |
      use Mojo::Base -strict; ...
```

### Written examples

The cURL and Perl examples are generated, and that is nearly always right.
Write `curl:` or `perl:` yourself only when a generated one can't work:
- a file upload (a multipart form)
- raw bytes in the body
- a header of the route's own

Use the same address (`https://api.mailmasker.org`), the same `$TOKEN`
and the same shape as the generated ones. The test still checks them for
tokens and real addresses.

### `who`

- **`anyone`:** no sign-in at all. The example sends no token.
- **`signed-in`:** any account.
- **`site-admin`:** site admins only.
- **`permission:<name>`:** site admins, and anyone granted that
  permission (`domains.catchall`, `metrics.view`, `audit.view`).
- **`fleet`:** only fleet services call it (heartbeats, registration,
  certificates, on-behalf calls). It is never shown. Such an entry needs
  only `id`, `title`, `method`, `path`, `who` and `summary`.

`who` is the least an account needs to call the route at all. When one
param needs more (say, `?user=` needs site admin), say so in that param's
`about`.

### Example values

- Never a real token, password, address or id.
- Use `{me}` for the reader's own address and `{domain}` for their domain.
  The site shows them as you@example.com and example.com.
- Otherwise use `example.com`.
- A value written `$NAME` (capitals) is an environment variable, such as
  `$REFRESH_TOKEN` or `$PASSWORD`. The cURL example lets the shell fill
  it in, and the Perl one reads `$ENV{NAME}`.
- Body params with an `example` make up the example body, in the order
  given. Query params with an `example` go in the example's URL, so leave
  `example` off an optional filter that would only clutter it.

### The response

One realistic answer, with the real field names the route returns. It
should be short: two or three items of a list are enough. Timestamps look
like Postgres's: `2026-11-03 21:42:10.123456-06`.

### Writing

- Plain words: say what it does for the person, not how it is built.
- `title` starts with a verb ("Block an address", "List your sessions").
- No table or column names in prose, unless the field is in the answer.
- `cli` is the exact homelab-cli command that calls this route, or
  `none`. Read `cli/homelab_cli/client.py`, which has one method per
  path, and find the command in `cli/homelab_cli/cli.py` that calls it.
