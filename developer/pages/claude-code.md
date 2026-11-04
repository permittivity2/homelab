# The Claude Code skill

A skill teaches Claude Code something it can use whenever it's needed. This one teaches it the MailMasker API. Ask Claude for what you want, such as "write a script that downloads everything in my Drive" or "block every address that sends me mail from example.net", and it looks up the exact calls in this reference as it works, so it is never working from an old copy.

## Install it

For you, in every project:

```
mkdir -p ~/.claude/skills/mailmasker-api
curl -fsSL {site}/skill/SKILL.md -o ~/.claude/skills/mailmasker-api/SKILL.md
```

Or for one project, so everyone who works on it has it. Commit the file with the project:

```
mkdir -p .claude/skills/mailmasker-api
curl -fsSL {site}/skill/SKILL.md -o .claude/skills/mailmasker-api/SKILL.md
```

Claude Code picks it up straight away. If `~/.claude/skills` didn't exist yet when your session started, type `/reload-skills`, or start Claude Code again.

## Use it

Claude uses it by itself when what you ask is about MailMasker, its api or homelab-cli. To call on it by name, type `/mailmasker-api` followed by what you want.

It reads [llms.txt](/llms.txt) to find the right ability, then that ability's page as Markdown for the exact parameters, answers and errors.

The skill lets Claude read developer.mailmasker.org without asking, for the request that uses it, and nothing else. Later in the same conversation Claude Code may ask again; to allow this site for good, choose "don't ask again" when it does, or add `WebFetch(domain:developer.mailmasker.org)` to `permissions.allow` in `~/.claude/settings.json`.

## Keep it current

When the API changes there is nothing to update: the skill reads this site every time. The skill file itself rarely changes. To get the newest, run the same `curl` again.

## What it says

{skill}
