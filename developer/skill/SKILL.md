---
name: mailmasker-api
description: Call the MailMasker API at api.mailmasker.org (sign-in and tokens, mail addresses and blocking, Drive files and shares, search, sessions, invites, domains and site administration) with cURL, Perl or homelab-cli, looking every call up in the live reference at developer.mailmasker.org. Use when the user wants to script, automate, integrate with or call MailMasker, mailmasker.org, api.mailmasker.org or homelab-cli.
allowed-tools: WebFetch(domain:developer.mailmasker.org)
---

# The MailMasker API

The reference at {site} is the source of truth, and it is kept current. For as long as this task lasts, look up every call there before writing or running it: never guess a path, parameter, field or status from memory.

## Look it up

1. Fetch {site}/llms.txt. It lists every ability: its title, method and path, who may use it, and a link to its page.
2. Fetch the page of the ability you need: the link from llms.txt, which ends in `.md` (such as {site}/sign-in.md). Ask for its complete text: it is short, and has the parameters, an example answer, the errors worth knowing, and examples in cURL, Perl and homelab-cli.
3. For signing in, tokens, errors and installing homelab-cli: {site}/getting-started.md.

A fetch can come back summarised. If a detail you need is missing, fetch the page again asking for exactly that, or read it whole with `curl -s` and the same address. {site}/reference.md has everything in one file, but it is too large to fetch in one go: use the pages.

## The basics

- Every call goes to {api}, and every path starts with `/api/v1`.
- Sign in with `POST /api/v1/auth/login` and `{"email": ..., "password": ...}`. The answer has `token` and `refresh_token`.
- Send `Authorization: Bearer <token>` with every call that needs a sign-in.
- A 401 means the token ran out: `POST /api/v1/auth/refresh` with `{"refresh_token": ...}`. A refresh token works once, so keep the new one it hands back.
- Errors come back as JSON: `{"error": "what went wrong"}`.
- Each page says who may use it. An admin or permission-only ability answers 403 to anyone else.

## When writing code or running calls for the user

- Use the user's real address, domain and ids. The reference's `you@example.com`, `example.com` and ids such as `42` are only examples.
- Read secrets from environment variables (`$TOKEN`, `$PASSWORD`, `$REFRESH_TOKEN`). Never write a real password or token into code, a file or a command line.
- If homelab-cli is installed (`command -v homelab-cli`), its command from the page is usually the simplest way to do one thing. It keeps its own sign-in.
- Perl examples use Mojo::UserAgent, as the reference does.
- Ask the user before any call that deletes, blocks, revokes, suspends, signs out or changes a password. Deleting Drive files through the API is immediate and permanent unless the page's `soft=1` is used; say so first.
