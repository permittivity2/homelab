# Getting started

Everything in this reference is something a MailMasker account can do from a script or the command line: the same things myaccount, webmail and Drive do for you. Each page has a ready-to-run example in cURL, Perl and homelab-cli.

## The address

Every call goes to `{api}`, followed by the path its page shows. The examples use `{me}` and `{domain}`: put your own address and domain in their place.

## 1. Get a token

[Sign in](/sign-in) with your address and password. The answer holds a `token`, good for `expires_in` seconds (a day, at present), and a `refresh_token`, good for 30 days.

The examples read the token from `$TOKEN`, so put it there once:

```
export TOKEN='…'
```

## 2. Send it with every call

As the header `Authorization: Bearer $TOKEN`. Every example already does.

## 3. When it runs out

A call answers 401. Get a fresh token with your refresh token ([Refresh your token](/refresh-token)), or sign in again. To end a session for good, [sign out](/sign-out).

## Who can use what

Each page says who may use it:

- **Anyone, with no sign-in**: no token needed.
- **Any signed-in account**: your own mail, addresses, files and sessions.
- **Site admins**: running the site.
- **Site admins, and accounts granted a permission**: such as catch-all routing, `domains.catchall`.

The services check every call for themselves, so a page you can read is not always a call you can make: an admin ability answers 403 to everyone else.

## When something goes wrong

- The answer has an `error` field saying what, in plain words, such as `{"error": "not logged in"}`.
- **400**: something is missing or has a wrong value. **401**: no token, or it ran out. **403**: your account may not do that. **404**: no such thing, or it isn't yours. **409**: it clashes with something already there. **429**: too many tries; wait and try again. **502**: a service behind the api isn't answering; try again shortly.
- After 10 failed sign-ins from one internet address within 15 minutes, signing in from that address is refused until the 15 minutes have passed.

## homelab-cli

The command-line client does all of this for you, and keeps your tokens. On Debian or Ubuntu:

```
sudo install -d /etc/apt/keyrings
curl -fsSL https://projects.thedude.vip/apt-homelab/homelab-archive-keyring.asc | sudo tee /etc/apt/keyrings/homelab.asc >/dev/null
echo 'deb [signed-by=/etc/apt/keyrings/homelab.asc] https://projects.thedude.vip/apt-homelab unstable main' | sudo tee /etc/apt/sources.list.d/homelab.list
sudo apt update && sudo apt install homelab-cli
```

Then point it at the api once, and sign in:

```
homelab-cli configure --api-base {api}
homelab-cli login {me}
```

## For tools and AI assistants

- [The Claude Code skill](/claude-code): Claude looks the calls up here as it works.
- [llms.txt](/llms.txt): an index of every page, for AI tools.
- [Everything as one Markdown file](/reference.md), and [as JSON](/reference.json).
- Every page is also plain Markdown: add `.md` to its address, as in [{site}/sign-in.md](/sign-in.md).
