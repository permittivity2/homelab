# homelab-developer

developer.mailmasker.org: the MailMasker API reference (post-cutover item
49). Public, no sign-in. Every ability a person or a script can use, by
area, each with who may use it, its parameters, an example answer, and
ready-to-run cURL, Perl and homelab-cli examples.

It is a static site, built when the package is. The host serving it
(prod-homelab45, behind the edge) runs only nginx.

## What is here

| | |
|---|---|
| `reference/*.yml` | The content: one file per area. The format is in `reference/README.md`. |
| `pages/*.md` | Getting started and the Claude Code page, in the little Markdown `md_to_html` reads. |
| `skill/SKILL.md` | The Claude Code skill, served at `/skill/SKILL.md`. |
| `lib/Homelab/Developer/Reference.pm` | Reads and checks the reference, and writes each ability's examples. |
| `lib/Homelab/Developer/Site.pm` | Builds the site. |
| `templates/` | The HTML pages, in the shared chrome from `../webtheme`. |
| `nginx/` | The site's nginx server block. |
| `t/` | `reference.t` (the reference against the code) and `site.t` (the built site). |

## What the site serves

| Address | What |
|---|---|
| `/` | Getting started |
| `/<id>` | One ability, such as `/sign-in` |
| `/<id>.md`, `/getting-started.md`, `/claude-code.md` | The same pages as Markdown, for tools and AI assistants |
| `/llms.txt` | An index of every Markdown page (llmstxt.org) |
| `/reference.md`, `/reference.json` | Everything in one file |
| `/claude-code`, `/skill/SKILL.md` | The Claude Code skill: how to install it, and the file |

## Changing it

1. Edit `reference/*.yml` (or `pages/`, `skill/`).
2. `prove -I lib t/` here.
3. Look at the result: `script/homelab-developer-build --out /some/empty/dir`.
4. Build and publish the package, then install it on prod-homelab45.

**An API call homelab-cli makes is documented here first**, released, and
only then is homelab-cli changed. `cli/tests/test_reference.py` holds that
rule: it fails, and with it homelab-cli's build, on any call in
`cli/homelab_cli/client.py` that this reference does not have.
