#!/bin/bash
# ============================================================================
# Deploy the www.mailmasker.org landing page (landing/site/) to prod-homelab45
# -- RUN ON THE ADMIN WORKSTATION (post-cutover #95).
#
#   ./landing-deploy.sh --dry-run    what differs between the repo and the host
#   ./landing-deploy.sh              push the files that differ (dated backup beside each)
#   ./landing-deploy.sh --verify     the live site is the repo's and answers from offsite
#
# The page is static files under /var/www/mailmasker on 45 (nginx vhost
# `mailmasker`; the apex 301s to www on that host). Only files that differ are
# pushed; a file that changes gets a dated backup beside it, the way the hand
# edits before this script did (#10, #46). Nothing is ever deleted on the host.
# ============================================================================
set -uo pipefail

HOST=10.20.2.189
ROOT=/var/www/mailmasker
SRC="$(cd "$(dirname "$0")/../landing/site" && pwd)"
THEME="$(cd "$(dirname "$0")/../webtheme/lib/Homelab" && pwd)/WebTheme.pm"
PUBLIC=https://www.mailmasker.org
STAGE=".landing-stage"

DRY=0; VERIFY_ONLY=0
for a in "$@"; do
    case "$a" in
        --dry-run) DRY=1 ;;
        --verify)  VERIFY_ONLY=1 ;;
        *) echo "unknown argument '$a' (usage: landing-deploy.sh [--dry-run] [--verify])"; exit 1 ;;
    esac
done

G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; D=$'\033[2m'; O=$'\033[0m'
ok(){   echo "  ${G}ok${O}   $*"; }
bad(){  echo "  ${R}FAIL${O} $*"; RC=1; }
warn(){ echo "  ${Y}warn${O} $*"; }
note(){ echo "  ${D}$*${O}"; }
step(){ echo; echo "=== $* ==="; }
RC=0
on(){ ssh -o ConnectTimeout=15 -o BatchMode=yes "$HOST" "$@"; }
off(){ ssh -n -o ConnectTimeout=15 -o BatchMode=yes offsite "$@"; }

# Every file of the site, relative to the web root.
mapfile -t FILES < <(cd "$SRC" && find . -type f | sed 's|^\./||' | sort)
[ "${#FILES[@]}" -gt 0 ] || { echo "no files under $SRC"; exit 1; }

# md5 of each file on the host ("missing" when it is not there). One ssh.
remote_sums(){
    on "cd $ROOT 2>/dev/null || exit 9; for f in $(printf '%q ' "${FILES[@]}"); do if [ -f \"\$f\" ]; then md5sum \"\$f\"; else echo \"missing  \$f\"; fi; done"
}
local_sum(){ md5sum "$SRC/$1" | cut -d' ' -f1; }

step "the repo against $HOST:$ROOT"
declare -A REMOTE=()
while read -r sum f; do [ -n "${f:-}" ] && REMOTE["$f"]="$sum"; done < <(remote_sums)
[ "${#REMOTE[@]}" -gt 0 ] || { bad "could not read $ROOT on $HOST"; exit 1; }
CHANGED=()
for f in "${FILES[@]}"; do
    if [ "${REMOTE[$f]:-}" = "$(local_sum "$f")" ]; then note "same      $f"; else CHANGED+=("$f"); echo "  ${Y}differs${O}   $f ${D}(host: ${REMOTE[$f]:-?})${O}"; fi
done
# Files on the host the repo does not have (its dated backups are expected).
while read -r f; do
    case "$f" in *.bak-*) ;; *) warn "on the host but not in the repo: $f (left alone)";; esac
done < <(on "cd $ROOT && find . -type f | sed 's|^\./||' | sort" | grep -vxF -f <(printf '%s\n' "${FILES[@]}"))

if [ "$VERIFY_ONLY" = 1 ]; then
    [ "${#CHANGED[@]}" = 0 ] && ok "every live file is the repo's" || bad "${#CHANGED[@]} live file(s) differ from the repo (run without --verify to push, or copy the host's version into landing/site/ if the hand edit is the one to keep)"

    step "the tiles against the theme's site list"
    theme=$(perl -ne 'print "$1 $2\n" if /href\s*=>\s*\x27([^\x27]+)\x27,\s*label\s*=>\s*\x27([^\x27]+)\x27,\s*icon/' "$THEME" | sort -f -k2,2)
    page=$(perl -0777 -ne 'print "$1 $2\n" while /class="launcher__tile"[^>]*href="([^"]+)">.*?<span class="launcher__label">([^<]+)<\/span>/g' "$SRC/index.html")
    [ -n "$theme" ] || bad "no default sites found in $THEME"
    [ -n "$page" ]  || bad "no launcher tiles found in $SRC/index.html"
    if [ "$theme" = "$page" ]; then ok "the page's tiles are the theme's sites, alphabetical: $(echo "$page" | awk '{print $2}' | paste -sd, - | sed 's/,/, /g')"; else bad "the tiles and the theme's sites differ"; diff <(echo "$theme") <(echo "$page") | sed 's/^/      /'; fi
    nos=$(perl -0777 -ne 'print "$1 $2\n" while /<li><a href="([^"]+)" class="nav__link">([^<]+)<\/a>/g' "$SRC/index.html")
    [ "$nos" = "$page" ] && ok "the <noscript> row lists the same six" || bad "the <noscript> row differs from the tiles"

    step "from offsite"
    if off true 2>/dev/null; then C(){ off "curl -sS -o /dev/null -w '%{http_code} %{redirect_url}' --max-time 15 $1" 2>/dev/null; }; body(){ off "curl -sS --max-time 15 $1" 2>/dev/null; }
    else warn "offsite does not answer; checking from here instead"; C(){ curl -sS -o /dev/null -w '%{http_code} %{redirect_url}' --max-time 15 "$1" 2>/dev/null; }; body(){ curl -sS --max-time 15 "$1" 2>/dev/null; }; fi
    r=$(C https://mailmasker.org/); [ "$r" = "301 $PUBLIC/" ] && ok "apex 301 -> $PUBLIC/" || bad "apex answered '$r', expected '301 $PUBLIC/'"
    html=$(body "$PUBLIC/")
    echo "$html" | grep -q 'class="launcher-btn"' && ok "the page has the launcher button" || bad "no launcher button in the live page"
    echo "$html" | grep -q 'static.mailmasker.org/theme/v1/shell.js' && ok "the page loads the theme's shell.js" || bad "the live page does not load shell.js"
    echo "$html" | grep -q 'class="nav__link"' && { echo "$html" | grep -q '<noscript>' && ok "the old row of links is inside <noscript> only" || bad "a plain row of links is still in the header"; }
    live=$(echo "$html" | perl -0777 -ne 'print "$1 $2\n" while /class="launcher__tile"[^>]*href="([^"]+)">.*?<span class="launcher__label">([^<]+)<\/span>/g')
    [ "$live" = "$theme" ] && ok "the live tiles are the theme's sites" || bad "the live tiles differ from the theme's sites"
    r=$(C "$PUBLIC/css/mailmasker.css"); [ "${r%% *}" = 200 ] && { body "$PUBLIC/css/mailmasker.css" | grep -q '\.launcher-btn' && ok "mailmasker.css has the launcher rules" || bad "the live mailmasker.css has no launcher rules"; } || bad "mailmasker.css -> '$r'"
    for p in /css/style.css /images/logo.svg /images/favicon.svg /images/bimi-logo.svg; do r=$(C "$PUBLIC$p"); [ "${r%% *}" = 200 ] && ok "$p -> 200" || bad "$p -> '$r'"; done
    r=$(C https://static.mailmasker.org/theme/v1/shell.js); [ "${r%% *}" = 200 ] && ok "shell.js answers from static.mailmasker.org" || bad "shell.js -> '$r'"

    step "result"; [ "$RC" = 0 ] && echo "  ${G}the live landing page is the repo's and answers with the launcher.${O}" || echo "  ${R}not clean -- see FAIL lines above.${O}"
    exit "$RC"
fi

if [ "${#CHANGED[@]}" = 0 ]; then step "result"; echo "  ${G}nothing to push: the host already has every file.${O}"; exit 0; fi

if [ "$DRY" = 1 ]; then
    step "would do"
    STAMP=YYYYMMDD-HHMMSS
    for f in "${CHANGED[@]}"; do [ -n "${REMOTE[$f]:-}" ] && [ "${REMOTE[$f]}" != missing ] && echo "  cp $ROOT/$f $ROOT/$f.bak-$STAMP; install $f" || echo "  install $f (new)"; done
    note "dry run: nothing changed."; exit 0
fi

step "pushing ${#CHANGED[@]} file(s) to $HOST"
STAMP=$(date +%Y%m%d-%H%M%S)
tar -C "$SRC" -cf - "${CHANGED[@]}" | on "rm -rf ~/$STAGE && mkdir -p ~/$STAGE && tar -xf - -C ~/$STAGE" || { bad "could not stage the files on $HOST"; exit 1; }
for f in "${CHANGED[@]}"; do
    if [ "${REMOTE[$f]:-missing}" != missing ]; then
        on "sudo cp -p $ROOT/$f $ROOT/$f.bak-$STAMP" && note "backup $ROOT/$f.bak-$STAMP" || { bad "could not back up $f -- stopping"; exit 1; }
    fi
    on "sudo install -d -o www-data -g www-data -m 775 \"\$(dirname $ROOT/$f)\" && sudo install -o www-data -g www-data -m 664 ~/$STAGE/$f $ROOT/$f" \
        && ok "installed $f" || { bad "could not install $f -- stopping"; exit 1; }
done
on "rm -rf ~/$STAGE"

step "re-reading the host"
declare -A AFTER=()
while read -r sum f; do [ -n "${f:-}" ] && AFTER["$f"]="$sum"; done < <(remote_sums)
for f in "${CHANGED[@]}"; do [ "${AFTER[$f]:-}" = "$(local_sum "$f")" ] && ok "$f is now the repo's" || bad "$f still differs after the push"; done
[ "$RC" = 0 ] || exit "$RC"
exec "$(cd "$(dirname "$0")" && pwd)/$(basename "$0")" --verify
