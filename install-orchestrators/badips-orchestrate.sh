#!/bin/bash
# ============================================================================
# bad-ips across the fleet (post-cutover item 33) -- RUN ON THE ADMIN
# WORKSTATION. Every step is workstation -> node over ssh; no node ever ssh's
# to another (the fleet's no-guest-to-guest-trust rule).
#
#   Build first: ../../bad-ips/build-package.sh X.Y.Z puts bad-ips into
#   ~/apt-repo-homelab. Every install below is then FROM THAT REPO, through
#   aptcacher, exactly as any fleet node would get it -- never a copied .deb.
#
#   ./badips-orchestrate.sh --rollout
#       everything below, in order, stopping at the first problem: --publish,
#       --proving-ground, --db, --deploy-web, --install on the canaries
#       ($CANARIES: one off node, one reporter), --install on every other
#       node, --static-realip, then edge-standby-sync.sh (closes SSH on the
#       parked edges). Blocking stays OFF: the edge only watches until
#       --role 00 block.
#   ./badips-orchestrate.sh --continue
#       the rest of --rollout after the database step, for when the first
#       three steps are already done. Stops at the first problem.
#   ./badips-orchestrate.sh --db
#       once: the shared ban list's login + schema in the fleet database, and
#       the login registered with pgbouncer 09/10/11. Safe to re-run: an
#       existing login keeps its password (resetting it would break every
#       node's config and pgbouncer's entry at once).
#   ./badips-orchestrate.sh --proving-ground
#       node 47 (a spare; PG_NODE=NN to pick another): installs the PUBLISHED
#       package in the block role, dropping ONLY on a made-up interface no
#       packet can arrive on, and WITH the shared list. Tests: a conflicting
#       leftover database file is refused and the service stays off; the
#       daemon connects to the fleet's shared list; the real firewall (table,
#       never-block, a ban, an nftables reload and a deleted table both
#       repaired, and how fast); a detection here reaches the shared list; a
#       ban in the list reaches the firewall here, and an unban lifts it; the
#       house and offsite cannot be banned. Then removes its test rows and
#       puts the node back to role off.
#   ./badips-orchestrate.sh --install [NN ...]
#       config + package on every node (default: every node 00-72 that
#       answers; parked edge nodes are reported and done in the rotation pass),
#       $PAR at a time, stopping after any batch with a problem. Each node is
#       checked against what its role needs (node_check), not just "installed".
#   ./badips-orchestrate.sh --role NN ROLE
#       ROLE = block | watch | report | off   (watch = block, firewall untouched)
#   ./badips-orchestrate.sh --static-realip
#       prod-homelab45's nginx logs the real visitor (files/real-ip-from-edge.conf).
#   ./badips-orchestrate.sh --api-grants
#       post-cutover #47: give the api's database login (homelab_api_runtime)
#       what it needs to list bans, end a ban and add an exemption on the
#       shared ban list. Run it BEFORE the api release that uses it.
#   ./badips-orchestrate.sh --verify [NN ...]
#       read-only: every node against node_check (version, role, files,
#       database and whether the daemon itself connected to it, service,
#       firewall table); the edge's ban/feed counts; the shared list's count.
#   ./badips-orchestrate.sh --upgrade [NN|ALIAS ...]
#       the package only (apt-get --only-upgrade), where it is installed,
#       roles untouched -- a blocking edge keeps blocking. Use this for a
#       version bump; --install on the live edge would reset it to watch.
#       Each target is checked afterwards; stops at the first wrong one.
#   ./badips-orchestrate.sh --publish [--deb FILE]
#       the fleet repo (with FILE added, if given) to prod-homelab45, then
#       asks apt on a fleet node, through aptcacher, what it now offers.
#   ./badips-orchestrate.sh --deploy-web
#       the real-visitor fixes (homelab-common 0.1.35, api 0.1.65, sso 0.1.18,
#       roundcube 0.1.27, webproxy 0.1.14) from the fleet repo, ONE node at a
#       time: api 12-14, sso 18-20, roundcube 42-44, the live edge, then every
#       other node. Only installed packages are upgraded, then each node's
#       homelab web apps (the hypnotoad units) are restarted so they load the
#       new request log -- never databases, pgbouncer, patroni or etcd -- and
#       checked before the next node. Stops at the first problem.
#   ./badips-orchestrate.sh --grafana-db
#       once (re-run to rotate): a READ-ONLY login, badips_grafana, that can read
#       one view (badips.offenders: active bans, rule, reporter, country, owner;
#       no log lines) and nothing else. Registered with pgbouncer 09/10/11, its
#       password written to /etc/homelab/grafana/ on the Grafana node ($GRAFANA_NODE,
#       default 69) with the database address, and homelab-grafana reinstalled so it
#       provisions the "bad-ips (shared ban list)" data source -- which it does only
#       once that password file exists. Needs bad-ips 4.2 applied (--db) first.
#   ./badips-orchestrate.sh --print-config NN|ALIAS
#       print the files the node would get (password masked); changes nothing.
#   ./badips-orchestrate.sh --db-login ALIAS
#       post-cutover #61: a legacy host's OWN login on the shared list,
#       badips_<alias>, a member of badips_runtime (same rights, now and for
#       whatever is granted to badips_runtime later), registered with pgbouncer
#       09/10/11, its password in ../../badips-db.<alias>.secret. One login per
#       internet-facing host, so a compromised host is answered with
#       ALTER ROLE badips_<alias> NOLOGIN instead of a fleet-wide rotation.
#       Safe to re-run: an existing login with its secret file keeps its password.
#
# Roles: edge 00/01/02 -> watch on first install (reports, blocks nothing;
#        switch on with --role 00 block); postfix 39/40/41 and dovecot VMs
#        62/63/64 -> report; every other node -> off (installed, switched off).
#
# Legacy hosts (post-cutover #61): --install, --role, --verify, --print-config
#        and --db-login also take an ssh alias from ~/.ssh/config ("jumper")
#        when it is listed in LEGACY_HOSTS in ../../badips-site.conf, e.g.
#        LEGACY_HOSTS="jumper=block:eth1,wlan0 ns03=off" (alias=role[:interfaces
#        a block host drops on]). A legacy block host watches on first install,
#        like an edge, until --role ALIAS block; it reports under its alias
#        (host_name) and uses its own login (--db-login ALIAS first). --install
#        also moves a legacy host's apt from the old 3.x repo (/apt) to the
#        fleet repo (/apt-homelab) -- never both. Legacy hosts are never part
#        of the default 00-72 set: name them.
#
# Site values -- the never-block list for the house and offsite, and the
# legacy hosts -- come from ../../badips-site.conf, NOT from git (both repos
# are public). The shared list's runtime password lives in
# ../../badips-db.secret (written by --db, mode 600); a legacy host's in
# ../../badips-db.<alias>.secret (--db-login). The script refuses to run
# without them.
# ============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOP="$(cd "$HERE/../.." && pwd)"                       # github-repos/homelab (outside git)
SITE="$TOP/badips-site.conf"
SECRET="$TOP/badips-db.secret"
SCHEMA_SQL="$TOP/../bad-ips/git/usr/local/share/bad_ips/schema.sql"
REALIP_CONF="$HERE/files/real-ip-from-edge.conf"

DB_NODES="06 07 08"
PGB_NODES="09 10 11"
PGB_VIP=10.50.2.131
EDGES="00 01 02"
REPORTERS="39 40 41 62 63 64"
STATIC_NODE=45
PG_NODE="${PG_NODE:-47}"
FIRST=0; LAST=72
PAR="${PAR:-10}"
CANARIES="12 39"                                        # first: one off node, one reporter
CONFDIR=/usr/local/etc/badips.d
SHIPPED_CONF="10-sshd.conf 20-postfix.conf 30-dovecot.conf 40-nginx.conf 50-apache.conf 60-rules.conf 70-bind.conf 80-publicblocklists.conf"
EXPECT_VERSION="${EXPECT_VERSION:-}"                    # set from the fleet repo before installing

# Leftovers of a bad-ips 3.x install baked into the fleet's base images (CTs
# 2026-06-13, VMs 2026-05-28; purged 2026-10-11, but purge never removed the
# files its installer GENERATED). badips.d/database.conf points at the dead
# database01 (10.10.0.116), with its password, and -- sorting after
# 96-fleet-db.conf -- silently won on the first rollout (2026-11-02; bad-ips
# 4.0.1 now refuses such a conflict instead). Removed ONLY when byte-identical
# to the copies inspected that day (the same on all 71 nodes); anything else
# stops that node's install for a human to look at.
LEFTOVERS="5f2a36a53e436a28e22577b4de9adb5ceece4e73082beb4afd302d942e306db2:/usr/local/etc/badips.conf
61ed4a90073312dea0fd1eafb0099a782ec831516ee0b1ad3a79e9b7fb772a4d:/usr/local/etc/badips.d/database.conf
208a1e910406326cdb4003f34fc7f0805ff1c2a3c922d802517467ab529c4d92:/usr/local/etc/badips.conf
dc2049c99914b934e33770c127ae242287eee399aa2542e6bf66d0a3ddec15e3:/usr/local/etc/badips.d/database.conf
80e6fe55e390f658b5d4c890990792d02d33c73f4655cf7f9598997a7982fc59:/usr/local/etc/badips.d/90-alwaysblock.conf
354923c0ed0824145f45a66f7e183afdef1ed9a4b00f636adcfebbfb0ed46487:/usr/local/etc/badips.d/10-sshd.conf.dpkg-dist
0b5e95f295498213c0cf8e898ffff09d523baa7f9ca22a2ad6e20f9efa0b8551:/usr/local/etc/badips.conf"
# Then jumper's hand-made 3.x files as read on 2026-11-07 (post-cutover #61):
# its main config, its database file (the dead database01 and a dead
# credential), its 1,685-range always-block list (archived in the item's
# evidence/ directory) and the .dpkg-dist the 4.2.0 upgrade left behind; and
# ns03's 3.7.0 main config (its database.conf is the fleet's known copy).

G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; B=$'\033[1m'; O=$'\033[0m'
FAILS=0
say(){ printf '\n%s== %s ==%s\n' "$B" "$*" "$O"; }
ok(){ printf '  %sok%s   %s\n' "$G" "$O" "$*"; }
bad(){ printf '  %sFAIL%s %s\n' "$R" "$O" "$*"; FAILS=$((FAILS + 1)); }
warn(){ printf '  %swarn%s %s\n' "$Y" "$O" "$*"; }
die(){ printf '%sERROR:%s %s\n' "$R" "$O" "$*" >&2; exit 2; }

# A target is a fleet node number (00-72 -> 10.20.2.(144+NN)) or, since
# post-cutover #61, a legacy host's ssh alias listed in LEGACY_HOSTS ("jumper").
is_legacy(){ case "$1" in ''|*[!0-9]*) return 0 ;; *) return 1 ;; esac; }
ip_of(){ if is_legacy "$1"; then printf '%s' "$1"; else printf '10.20.2.%d' "$((144 + 10#$1))"; fi; }
rsh(){ local n="$1"; shift; ssh -o BatchMode=yes -o ConnectTimeout=6 -o StrictHostKeyChecking=accept-new "$(ip_of "$n")" "$@"; }
up(){ timeout 12 ssh -o BatchMode=yes -o ConnectTimeout=5 "$(ip_of "$1")" true 2>/dev/null; }
nn(){ if is_legacy "$1"; then printf '%s' "$1"; else printf '%02d' "$((10#$1))"; fi; }
label(){ if is_legacy "$1"; then printf '%s' "$1"; else printf 'prod-homelab%s' "$(nn "$1")"; fi; }

# legacy_spec ALIAS -> "role[:interfaces]" from LEGACY_HOSTS, or non-zero
legacy_spec(){ local e; for e in ${LEGACY_HOSTS:-}; do [ "${e%%=*}" = "$1" ] && { printf '%s' "${e#*=}"; return 0; }; done; return 1; }
legacy_role(){ local s; s="$(legacy_spec "$1")" || return 1; printf '%s' "${s%%:*}"; }
# what a block host drops on: the edge's two interfaces, or the legacy host's own
ifaces_for(){ local s; if is_legacy "$1"; then s="$(legacy_spec "$1")" && case "$s" in *:*) printf '%s' "${s#*:}" | sed 's/,/, /g' ;; esac; else printf 'eth6, eth7'; fi; }
is_block_host(){ if is_legacy "$1"; then [ "$(legacy_role "$1" 2>/dev/null)" = block ]; else case " $EDGES " in *" $1 "*) return 0 ;; *) return 1 ;; esac; fi; }

# the role a target gets on --install: a block host WATCHES first (reports,
# blocks nothing) until --role TARGET block
role_for(){
    if is_legacy "$1"; then
        local r; r="$(legacy_role "$1")" || die "$1 is not in LEGACY_HOSTS ($SITE)"
        [ "$r" = block ] && echo watch || echo "$r"; return
    fi
    case " $EDGES " in *" $1 "*) echo watch; return ;; esac
    case " $REPORTERS " in *" $1 "*) echo report; return ;; esac
    echo off
}

# the shared list's login a target uses: the fleet's, or the legacy host's own
db_user_for(){ if is_legacy "$1"; then printf 'badips_%s' "$(printf '%s' "$1" | tr -c 'a-z0-9\n' '_')"; else printf 'badips_runtime'; fi; }
secret_file_for(){ printf '%s/badips-db.%s.secret' "$TOP" "$1"; }
# load_secret_for TARGET -> DB_USER and DB_PASS for its 96-fleet-db.conf
load_secret_for(){
    if is_legacy "$1"; then
        local f keep; f="$(secret_file_for "$1")"
        [ -f "$f" ] || die "missing $f -- run --db-login $1 first (its own login on the shared list)"
        keep="${BADIPS_DB_PASSWORD:-}"; BADIPS_DB_USER=''
        # shellcheck disable=SC1090
        . "$f"
        DB_USER="${BADIPS_DB_USER:-}"; DB_PASS="${BADIPS_DB_PASSWORD:-}"; BADIPS_DB_PASSWORD="$keep"
        [ "$DB_USER" = "$(db_user_for "$1")" ] && [ -n "$DB_PASS" ] || die "$f must set BADIPS_DB_USER='$(db_user_for "$1")' and BADIPS_DB_PASSWORD"
    else
        load_secret; DB_USER=badips_runtime; DB_PASS="$BADIPS_DB_PASSWORD"
    fi
}

load_site(){
    [ -f "$SITE" ] || die "missing $SITE (the never-block list for the house and offsite; kept out of the public repos)"
    # shellcheck disable=SC1090
    . "$SITE"
    [ -n "${NEVER_BLOCK:-}" ] || die "$SITE does not set NEVER_BLOCK"
    # The values themselves stay out of this script (it is in a public repo);
    # what is checked is the shape: the house and offsite, so at least two
    # IPv4 networks and one IPv6 network, each well-formed.
    local e v4=0 v6=0
    for e in ${NEVER_BLOCK//,/ }; do
        case "$e" in
            *:*) [[ "$e" =~ ^[0-9A-Fa-f:]+(/[0-9]{1,3})?$ ]] && v6=$((v6 + 1)) || die "$SITE: '$e' is not an IPv6 network" ;;
            *)   [[ "$e" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]] && v4=$((v4 + 1)) || die "$SITE: '$e' is not an IPv4 network" ;;
        esac
    done
    [ "$v4" -ge 2 ] && [ "$v6" -ge 1 ] || die "$SITE: NEVER_BLOCK must hold the house and offsite (2+ IPv4, 1+ IPv6 networks); it has $v4 and $v6"
    # LEGACY_HOSTS (optional): alias=role[:iface,iface] -- the alias is an ssh
    # config name, the role block|report|off, interfaces only (and always) with block
    local a r
    for e in ${LEGACY_HOSTS:-}; do
        a="${e%%=*}"; r="${e#*=}"
        [[ "$a" =~ ^[a-z][a-z0-9-]*$ ]] && [ "$a" != "$e" ] || die "$SITE: LEGACY_HOSTS entry '$e' is not alias=role[:interfaces]"
        case "$r" in
            block:*) [[ "${r#block:}" =~ ^[a-z0-9.-]+(,[a-z0-9.-]+)*$ ]] || die "$SITE: LEGACY_HOSTS '$a': block needs interfaces, e.g. block:eth1,wlan0" ;;
            report|off) ;;
            *) die "$SITE: LEGACY_HOSTS '$a': role must be block:IFACES, report or off (got '$r')" ;;
        esac
    done
}
# the first address of every IPv4 never-block network (each is on the list)
never_v4(){ local e; for e in ${NEVER_BLOCK//,/ }; do case "$e" in *:*) ;; *) echo "${e%%/*}" ;; esac; done; }
load_secret(){
    [ -f "$SECRET" ] || die "missing $SECRET -- run --db first"
    # shellcheck disable=SC1090
    . "$SECRET"
    [ -n "${BADIPS_DB_PASSWORD:-}" ] || die "$SECRET does not set BADIPS_DB_PASSWORD"
}

# --- the three config files every node gets --------------------------------
HDR="# Written by homelab install-orchestrators/badips-orchestrate.sh -- edit there, not here."
# conf_role ROLE [IFACES] [NAME] -- IFACES: what a block host drops on (default
# the edge's two); NAME: a legacy host, which reports under that name.
conf_role(){
    local ifs="${2:-eth6, eth7}" name="${3:-}"
    printf '%s\n[global]\n' "$HDR"
    case "$1" in
        watch)  if [ -n "$name" ]; then printf '# %s, in WATCH mode: detects and reports, blocks nothing.\n' "$name"
                else printf '# The edge, in WATCH mode: detects and reports, blocks nothing.\n'; fi
                printf 'role = block\ndry_run = 1\nblock_interfaces = %s\n' "$ifs" ;;
        block)  if [ -n "$name" ]; then printf '# %s: drops shared-list and feed addresses, on its internet-facing interfaces only.\n' "$name"
                else printf '# The edge: drops shared-list and feed addresses, on its two internet-facing interfaces only.\n'; fi
                printf 'role = block\ndry_run = 0\nblock_interfaces = %s\n' "$ifs" ;;
        report) printf '# Reports attackers to the shared ban list; never blocks.\nrole = report\n' ;;
        off)    printf '# Installed and configured, switched off.\nrole = off\n' ;;
    esac
    [ -z "$name" ] || printf '# A legacy host, not a prod-homelabNN: this is the name on the shared list,\n# and it has no node-exporter textfile directory to publish numbers into.\nhost_name = %s\nmetrics_dir =\n' "$name"
}
conf_fleet(){
    printf '%s\n# Identical on every node.\n[global]\nnever_block_cidrs = %s\n' "$HDR" "$NEVER_BLOCK"
}
# conf_db -- DB_USER / DB_PASS from load_secret_for (the fleet's login, or a
# legacy host's own)
conf_db(){
    printf '%s\n# The shared ban list, through the pgbouncer VIP. Only on nodes whose role uses it.\n[global]\n' "$HDR"
    printf 'db_host = %s\ndb_port = 6432\ndb_name = homelab\ndb_user = %s\ndb_password = %s\ndb_schema = badips\n' \
        "$PGB_VIP" "${DB_USER:-badips_runtime}" "${DB_PASS:-${BADIPS_DB_PASSWORD:-}}"
}

# put NN PATH  < content   (root:badips 0640 once the group exists)
put(){
    rsh "$1" "sudo sh -c 'umask 027; mkdir -p $CONFDIR && cat > $2.new && { chgrp badips $2.new 2>/dev/null || true; } && chmod 0640 $2.new && mv -f $2.new $2'"
}

# retire_leftovers NN -- removes the known leftovers (see LEFTOVERS) and
# says so; non-zero, touching nothing, when a file there is NOT the known one.
retire_leftovers(){
    { printf 'LEFTOVERS=%q\n' "$LEFTOVERS"
      cat <<'EOS'
rc=0; seen=''
# a path may be listed with several known hashes (the fleet's copy, jumper's):
# remove it when ANY matches; what is left afterwards is unknown
for e in $LEFTOVERS; do
    h=${e%%:*}; f=${e#*:}
    [ -f "$f" ] || continue
    [ "$(sha256sum < "$f" | cut -d' ' -f1)" = "$h" ] && rm -f "$f" && echo "removed the known leftover $f"
done
for e in $LEFTOVERS; do
    f=${e#*:}
    case " $seen " in *" $f "*) continue ;; esac; seen="$seen $f"
    [ -e "$f" ] && { echo "UNKNOWN $f: not a known leftover -- left alone, look at it"; rc=1; }
done
exit $rc
EOS
    } | rsh "$1" "sudo bash -s"
}

write_config(){ # TARGET ROLE
    local n="$1" role="$2" name=''
    retire_leftovers "$n" || return 1
    is_legacy "$n" && name="$n"
    conf_role "$role" "$(ifaces_for "$n")" "$name" | put "$n" "$CONFDIR/94-role.conf" || return 1
    conf_fleet                                     | put "$n" "$CONFDIR/95-fleet.conf" || return 1
    if [ "$role" = off ]; then
        rsh "$n" "sudo rm -f $CONFDIR/96-fleet-db.conf" || return 1
    else
        load_secret_for "$n"
        conf_db | put "$n" "$CONFDIR/96-fleet-db.conf" || return 1
    fi
}

# fleet_repo_on TARGET -- a legacy host gets bad-ips from the fleet repo
# (projects.thedude.vip/apt-homelab, the directory --publish fills), not from
# the old 3.x repo (/apt). A host must never have both (bad-ips/build-package.sh):
# the old source is removed, the fleet one added, idempotently.
fleet_repo_on(){
    rsh "$1" "sudo bash -s" <<'EOS'
old='http://projects.thedude.vip/apt '
new='deb [signed-by=/etc/apt/keyrings/silver-linings.gpg] http://projects.thedude.vip/apt-homelab unstable main'
[ -f /etc/apt/keyrings/silver-linings.gpg ] || { echo "no /etc/apt/keyrings/silver-linings.gpg here"; exit 1; }
for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
    [ -f "$f" ] && grep -qF "$old" "$f" || continue
    sed -i "\#${old}#d" "$f"; echo "removed the old 3.x repo line from $f"
    [ -s "$f" ] || { rm -f "$f"; echo "removed the now empty $f"; }
done
grep -qsF 'projects.thedude.vip/apt-homelab' /etc/apt/sources.list /etc/apt/sources.list.d/*.list \
    || { printf '%s\n' "$new" > /etc/apt/sources.list.d/silver-linings-homelab.list; echo "added the fleet repo (/etc/apt/sources.list.d/silver-linings-homelab.list)"; }
EOS
}

# install_pkg NN [DEB] -- install (or upgrade) then re-run postinst, so the
# role in the config just written decides the service state.
install_pkg(){
    local n="$1" deb="${2:-}"
    if [ -n "$deb" ]; then
        rsh "$n" "cat > /home/gardner/$(basename "$deb")" < "$deb" || return 1
        rsh "$n" "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q /home/gardner/$(basename "$deb") >/tmp/badips-install.log 2>&1 \
                  && sudo dpkg-reconfigure -f noninteractive bad-ips >>/tmp/badips-install.log 2>&1; rc=\$?; rm -f /home/gardner/$(basename "$deb"); exit \$rc"
    else
        # Shipped config files edited by an older install (dpkg -V: md5 differs
        # on a conffile) are removed first and come back from the package
        # (--force-confmiss), so a 3.x-era file never shadows what 4.x ships.
        # Nothing of the fleet's own lives in them (that is 94/95/96).
        rsh "$n" "sudo bash -s" <<'EOS'
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/tmp/badips-install.log 2>&1
apt-get install -y -q bad-ips >>/tmp/badips-install.log 2>&1 || exit 1
# Checked AFTER the install: a 3.x package did not own badips.d/* as conffiles,
# so its copies only show up as "edited" once 4.x is on. dpkg keeps such a copy
# (and parks the new one as .dpkg-dist); remove them and let the package put
# its own back.
mods=$(dpkg -V bad-ips 2>/dev/null | awk '$2 == "c" && substr($1, 3, 1) == "5" {print $3}' | grep -E '^/usr/local/etc/badips' || true)
if [ -n "$mods" ]; then
    rm -f $mods
    apt-get install -y -q --reinstall -o Dpkg::Options::=--force-confmiss bad-ips >>/tmp/badips-install.log 2>&1 || exit 1
    echo "restored shipped file(s): $(echo $mods | tr '\n' ' ')"
fi
rm -f /usr/local/etc/badips.d/*.dpkg-dist /usr/local/etc/badips.d/*.dpkg-old /usr/local/etc/badips.d/*.dpkg-new
dpkg-reconfigure -f noninteractive bad-ips >>/tmp/badips-install.log 2>&1
EOS
    fi
}

# node_status NN -> one line of key=value, values without spaces, except the
# LAST field (first_warn=...), which is free text. Waits up to 30 s for a
# running daemon that uses the shared list to log its connection: the
# DAEMON's own connection is what counts (--test-config alone proved nothing
# on 2026-11-02 -- nobody asked it which database it meant).
node_status(){
    rsh "$1" "sudo bash -s" 2>/dev/null <<'EOS' || echo unreachable
v=$(dpkg-query -W -f='${Version}' bad-ips 2>/dev/null); [ -n "$v" ] || v=none
tc=$(/usr/local/sbin/bad_ips --test-config 2>&1); tcrc=$?
[ -x /usr/local/sbin/bad_ips ] || tcrc=9
r=$(printf '%s\n' "$tc" | sed -n 's/^role: *\([a-z]*\).*/\1/p' | head -1)
printf '%s\n' "$tc" | grep -q '^role:.*watch mode' && r=watch
db=$(printf '%s\n' "$tc" | sed -n 's/^database: *\([^ ]*\) as \([^,]*\),.*/\2@\1/p; s/^database: *none.*/none/p' | head -1)
reach=$(printf '%s\n' "$tc" | sed -n 's/^ *reachable;.*/yes/p; s/^ *NOT reachable.*/NO/p' | head -1)
e=$(systemctl is-enabled bad_ips 2>/dev/null); a=$(systemctl is-active bad_ips 2>/dev/null)
t=$(nft list table inet badips >/dev/null 2>&1 && echo yes || echo no)
files=$(ls /usr/local/etc/badips.d 2>/dev/null | grep '\.conf$' | paste -sd,)
main=$([ -e /usr/local/etc/badips.conf ] && echo present || echo absent)
# shipped config files that differ from the package (an older install's edits)
cf=$(dpkg -V bad-ips 2>/dev/null | awk '$2 == "c" && substr($1, 3, 1) == "5" {print $3}' | grep -cE '^/usr/local/etc/badips')
conn=-; warns=-; first=
L=/var/log/bad_ips/bad_ips.log
# The running daemon's own lines, oldest first, from EVERY file logrotate has
# kept: the daily rotation moves its start-up lines (the connection among
# them) out of bad_ips.log, which made three healthy reporters look
# unconnected on 2026-11-03. Matched by PID AND start time, so a recycled PID
# in an older file cannot count.
mine(){ for f in $L*; do zcat -f "$f"; done 2>/dev/null | awk -F'|' -v p="$pid" -v s="$since" '$2 == p && $1 >= s' | LC_ALL=C sort -s -t'|' -k1,1; }
if [ "$a" = active ]; then
    pid=$(systemctl show -p MainPID --value bad_ips)
    since=$(date -d "$(systemctl show -p ExecMainStartTimestamp --value bad_ips)" '+%Y/%m/%d %H:%M:%S' 2>/dev/null)
    if [ "$db" != none ]; then
        for i in $(seq 1 30); do mine | grep -q '|INFO|.*shared ban list: connected to ' && break; sleep 1; done
    fi
    # a BLOCKING daemon builds its table right after connecting; asked a second
    # too early (--role X block on 2026-11-07), "no firewall table" was a false
    # failure. Give it one reconcile.
    if [ "$r" = block ]; then
        for i in $(seq 1 35); do nft list table inet badips >/dev/null 2>&1 && break; sleep 1; done
        t=$(nft list table inet badips >/dev/null 2>&1 && echo yes || echo no)
    fi
    M=$(mine)
    conn=$(printf '%s\n' "$M" | grep '|INFO|.*shared ban list: connected to ' | tail -1 | sed 's/.*connected to //')
    [ -n "$conn" ] || conn=NO
    warns=$(printf '%s\n' "$M" | grep -cE '^[^|]*\|[^|]*\|(WARN|ERROR|FATAL)\|')
    first=$(printf '%s\n' "$M" | grep -E '^[^|]*\|[^|]*\|(WARN|ERROR|FATAL)\|' | head -1 | cut -d'|' -f6- | cut -c1-200)
fi
echo "version=$v role=${r:-?} config=$([ "$tcrc" = 0 ] && echo ok || echo REFUSED) db=${db:-?} reach=${reach:--} daemon_db=$conn warns=$warns enabled=${e:-?} active=${a:-?} table=$t mainconf=$main files=${files:-none} conffiles=${cf:-?} first_warn=$first"
EOS
}

# node_check WANT STATUS [DBUSER] -> nothing and 0 when a node is exactly what
# its role needs; else the problems and 1. The ONE definition of "right".
# DBUSER: the login this target must use (default the fleet's).
node_check(){
    local want="$1" st="$2" dbu="${3:-badips_runtime}" p=() x files expect fleet
    fleet="$dbu@$PGB_VIP:6432/homelab"
    sf(){ printf '%s\n' "${st% first_warn=*}" | tr ' ' '\n' | sed -n "s/^$1=//p" | head -1; }
    [ "$st" = unreachable ] && { echo unreachable; return 1; }
    [ -z "$EXPECT_VERSION" ] || [ "$(sf version)" = "$EXPECT_VERSION" ] || p+=("version $(sf version), want $EXPECT_VERSION")
    [ "$(sf config)" = ok ]       || p+=("configuration REFUSED (sudo bad_ips --test-config says why)")
    [ "$(sf role)" = "$want" ]    || p+=("role $(sf role), want $want")
    [ "$(sf mainconf)" = absent ] || p+=("/usr/local/etc/badips.conf present")
    [ "$(sf conffiles)" = 0 ]     || p+=("$(sf conffiles) shipped config file(s) edited (dpkg -V bad-ips); --install restores them")
    files="$(sf files)"; expect="$SHIPPED_CONF 94-role.conf 95-fleet.conf"; [ "$want" = off ] || expect="$expect 96-fleet-db.conf"
    for x in ${files//,/ }; do case " $expect " in *" $x "*) ;; *) p+=("unexpected badips.d/$x") ;; esac; done
    for x in $expect; do case ",$files," in *",$x,"*) ;; *) p+=("missing badips.d/$x") ;; esac; done
    if [ "$want" = off ]; then
        [ "$(sf db)" = none ]                                || p+=("database $(sf db) configured on an off node")
        [ "$(sf enabled)/$(sf active)" = disabled/inactive ] || p+=("service $(sf enabled)/$(sf active), want disabled/inactive")
        [ "$(sf table)" = no ]                               || p+=("firewall table present")
    else
        [ "$(sf db)" = "$fleet" ]                            || p+=("database $(sf db), want $fleet")
        [ "$(sf reach)" = yes ]                              || p+=("the shared list is not reachable")
        [ "$(sf daemon_db)" = "$fleet" ]                     || p+=("the daemon did not connect to $fleet (it says: $(sf daemon_db))")
        [ "$(sf warns)" = 0 ]                                || p+=("$(sf warns) warning line(s) from the running daemon, first: ${st##* first_warn=}")
        [ "$(sf enabled)/$(sf active)" = enabled/active ]    || p+=("service $(sf enabled)/$(sf active), want enabled/active")
        case "$want" in block) [ "$(sf table)" = yes ] || p+=("no firewall table") ;;
                        *)     [ "$(sf table)" = no ]  || p+=("a firewall table, which $want never has") ;; esac
    fi
    [ ${#p[@]} -eq 0 ] && return 0
    local IFS=';'; echo "${p[*]}"; return 1
}

# the one-line summary printed for a node that passed node_check
node_brief(){ local st="$1"; printf '%s\n' "${st% first_warn=*}" | tr ' ' '\n' | grep -E '^(version|role|daemon_db|enabled|active|table)=' | paste -sd' '; }

repo_version(){ reprepro -b "$REPO_DIR" list unstable bad-ips 2>/dev/null | awk '{print $NF}' | sort -uV | tail -1; }

# ============================================================================
# --db
# ============================================================================
find_leader(){
    local n r
    for n in $DB_NODES; do
        r="$(rsh "$n" "sudo -u postgres psql -tAXc 'SELECT pg_is_in_recovery()'" 2>/dev/null | tr -d '[:space:]')" || true
        [ "$r" = f ] && { printf '%s' "$n"; return 0; }
    done
    return 1
}

GRAFANA_NODE="${GRAFANA_NODE:-69}"
do_api_grants(){
    say "give the api's database login its rights on the ban list (post-cutover #47)"
    local leader role=homelab_api_runtime q
    leader="$(find_leader)" || die "no Patroni leader among $DB_NODES"
    ok "Patroni leader: prod-homelab$leader"
    rsh "$leader" "sudo -u postgres psql -d homelab -tAXc \"SELECT to_regclass('badips.jailed_ips')\"" | grep -q jailed_ips \
        || die "badips.jailed_ips does not exist: run --db first"
    rsh "$leader" "sudo -u postgres psql -d homelab -tAXc \"SELECT 1 FROM pg_roles WHERE rolname='$role'\"" | grep -q 1 \
        || die "no role $role on the database"
    # Read the list; end a ban (only its expiry column); add an exemption. Nothing else:
    # no DELETE, no new bans, no edits to rules or evidence.
    { echo "GRANT USAGE ON SCHEMA badips TO $role;"
      echo "GRANT SELECT ON badips.jailed_ips, badips.exemptions, badips.ip_geo TO $role;"
      echo "GRANT UPDATE (expires_at) ON badips.jailed_ips TO $role;"
      echo "GRANT INSERT ON badips.exemptions TO $role;"
      echo "GRANT USAGE ON SEQUENCE badips.exemptions_id_seq TO $role;"; } \
      | rsh "$leader" "sudo -u postgres psql -d homelab -X -q -v ON_ERROR_STOP=1" || die "the grants failed"
    ok "$role: read the list, end a ban's expiry, add an exemption"
    q="SELECT has_table_privilege('$role','badips.jailed_ips','SELECT'), has_column_privilege('$role','badips.jailed_ips','expires_at','UPDATE'), has_table_privilege('$role','badips.jailed_ips','DELETE'), has_table_privilege('$role','badips.jailed_ips','INSERT'), has_column_privilege('$role','badips.jailed_ips','matched_log_line','UPDATE'), has_table_privilege('$role','badips.exemptions','INSERT')"
    [ "$(rsh "$leader" "sudo -u postgres psql -d homelab -tAXc \"$q\"" | tr -d '[:space:]')" = "t|t|f|f|f|t" ] \
        && ok "can read, end bans and add exemptions; cannot delete, insert bans or edit evidence" \
        || bad "the privileges are not what was intended: $q"
}

do_grafana_db(){
    say "a read-only login for Grafana's bad-ips panels"
    local leader pw scram p n
    leader="$(find_leader)" || die "no Patroni leader among $DB_NODES"
    ok "Patroni leader: prod-homelab$leader"
    rsh "$leader" "sudo -u postgres psql -d homelab -tAXc \"SELECT to_regclass('badips.offenders')\"" | grep -q offenders \
        || die "badips.offenders does not exist: run --db with bad-ips 4.2's schema.sql first"
    pw="$(openssl rand -hex 20)"
    # the password travels on stdin, never on a command line
    { printf "DO \$\$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'badips_grafana') THEN CREATE ROLE badips_grafana LOGIN; END IF; END \$\$;\n"
      printf "ALTER ROLE badips_grafana PASSWORD '%s';\n" "$pw"
      echo "ALTER ROLE badips_grafana IN DATABASE homelab SET search_path = badips;"
      echo "GRANT USAGE ON SCHEMA badips TO badips_grafana;"
      echo "GRANT SELECT ON badips.offenders TO badips_grafana;"; } \
      | rsh "$leader" "sudo -u postgres psql -d homelab -X -q -v ON_ERROR_STOP=1" || die "creating the login failed"
    ok "login badips_grafana: SELECT on badips.offenders only"
    scram="$(rsh "$leader" "sudo -u postgres psql -d homelab -tAXc \"SELECT rolpassword FROM pg_authid WHERE rolname = 'badips_grafana'\"" | tr -d '[:space:]')"
    [ -n "$scram" ] || die "could not read the login's SCRAM secret"
    for p in $PGB_NODES; do
        printf "homelab-bootstrap-pgbouncer-entry --role badips_grafana --scram-secret '%s' --pgbouncer-host localhost\n" "$scram" \
            | rsh "$p" "sudo bash -s" >/dev/null 2>&1 && ok "registered with pgbouncer on prod-homelab$p" || bad "pgbouncer registration on prod-homelab$p"
    done
    # end to end, as Grafana will connect: through the VIP; and it must NOT read the log lines
    n="$(printf "PGPASSWORD='%s' psql 'host=%s port=6432 dbname=homelab user=badips_grafana sslmode=prefer' -tAXc 'SELECT count(*) FROM offenders'\n" "$pw" "$PGB_VIP" | rsh "$leader" "bash -s" 2>&1 | tr -d '[:space:]')"
    if [[ "$n" =~ ^[0-9]+$ ]]; then ok "reads the offenders view through pgbouncer ($n rows)"; else bad "read through pgbouncer: $n"; fi
    n="$(printf "PGPASSWORD='%s' psql 'host=%s port=6432 dbname=homelab user=badips_grafana sslmode=prefer' -tAXc 'SELECT count(*) FROM jailed_ips' 2>&1\n" "$pw" "$PGB_VIP" | rsh "$leader" "bash -s" 2>&1)"
    if printf '%s' "$n" | grep -qi 'permission denied'; then ok "cannot read the underlying table (permission denied, as intended)"; else bad "the login can read jailed_ips: $n"; fi
    # hand the password and the address to the Grafana node
    printf '%s\n' "$pw" | rsh "$GRAFANA_NODE" "sudo sh -c 'install -d -m 0755 /etc/homelab/grafana; umask 027; cat > /etc/homelab/grafana/badips-db.password.new; chgrp grafana /etc/homelab/grafana/badips-db.password.new; chmod 0640 /etc/homelab/grafana/badips-db.password.new; mv -f /etc/homelab/grafana/badips-db.password.new /etc/homelab/grafana/badips-db.password'" \
        && ok "password placed on prod-homelab$GRAFANA_NODE" || bad "placing the password"
    printf 'BADIPS_DB_HOST=%s\nBADIPS_DB_PORT=6432\n' "$PGB_VIP" \
        | rsh "$GRAFANA_NODE" "sudo sh -c 'cat > /etc/homelab/grafana/badips-db.conf && chmod 0644 /etc/homelab/grafana/badips-db.conf'" \
        && ok "database address written to /etc/homelab/grafana/badips-db.conf" || bad "writing the address"
    rsh "$GRAFANA_NODE" "sudo apt-get update -qq >/dev/null 2>&1; sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --reinstall homelab-grafana >/dev/null 2>&1 >/dev/null 2>&1; sleep 10; systemctl is-active grafana-server; ls /etc/grafana/provisioning/datasources/" | sed 's/^/    /'
}

do_db(){
    load_site
    [ -f "$SCHEMA_SQL" ] || die "missing $SCHEMA_SQL (the bad-ips repo checkout)"
    say "the shared ban list in the fleet database"
    local leader; leader="$(find_leader)" || die "no Patroni leader among $DB_NODES"
    ok "Patroni leader: prod-homelab$leader"

    local exists
    exists="$(rsh "$leader" "sudo -u postgres psql -d homelab -tAXc \"SELECT 1 FROM pg_roles WHERE rolname = 'badips_runtime'\"" | tr -d '[:space:]')"
    if [ "$exists" = 1 ]; then
        [ -f "$SECRET" ] || die "badips_runtime already exists but $SECRET is missing. Not resetting its password (that breaks every node at once); recover the password from a node's $CONFDIR/96-fleet-db.conf into $SECRET."
        load_secret
        ok "login badips_runtime already exists; its password is kept"
    else
        local out pw manual
        out="$(rsh "$leader" "sudo homelab-bootstrap-app-role --feature badips --schema badips --db-host localhost")" \
            || die "homelab-bootstrap-app-role failed on prod-homelab$leader"
        manual="$(printf '%s\n' "$out" | sed -n 's/^BOOTSTRAP_MANUAL=//p')"
        pw="$(printf '%s\n' "$out" | sed -n 's/^RUNTIME_PASSWORD=//p')"
        [ "$manual" = 0 ] && [ -n "$pw" ] || die "bootstrap did not complete on the leader (BOOTSTRAP_MANUAL=$manual)"
        ( umask 077; printf "# The bad-ips shared ban list's runtime password (login badips_runtime). Written by\n# badips-orchestrate.sh --db on %s. Not in git.\nBADIPS_DB_PASSWORD='%s'\n" "$(date -Is)" "$pw" > "$SECRET" )
        BADIPS_DB_PASSWORD="$pw"
        ok "created logins badips_runtime + badips_migrate and schema badips (password saved to $SECRET)"
    fi

    # search_path, then the tables -- created AS badips_migrate, so the
    # runtime login's default privileges cover them (created as postgres,
    # the runtime login would get "permission denied" and fail quietly).
    { echo "ALTER ROLE badips_runtime IN DATABASE homelab SET search_path = badips;"
      echo "ALTER ROLE badips_migrate IN DATABASE homelab SET search_path = badips;"
      echo "SET client_min_messages = warning;"
      echo "SET ROLE badips_migrate;"
      echo "SET search_path = badips;"
      cat "$SCHEMA_SQL"; } | rsh "$leader" "sudo -u postgres psql -d homelab -X -q -v ON_ERROR_STOP=1" \
        || die "applying schema.sql failed"
    ok "tables jailed_ips + exemptions in place (owned by badips_migrate)"

    local scram p
    scram="$(rsh "$leader" "sudo -u postgres psql -d homelab -tAXc \"SELECT rolpassword FROM pg_authid WHERE rolname = 'badips_runtime'\"" | tr -d '[:space:]')"
    [ -n "$scram" ] || die "could not read badips_runtime's SCRAM secret"
    for p in $PGB_NODES; do
        # the secret travels on stdin, never on a command line
        printf "homelab-bootstrap-pgbouncer-entry --role badips_runtime --scram-secret '%s' --pgbouncer-host localhost\n" "$scram" \
            | rsh "$p" "sudo bash -s" >/dev/null 2>&1 && ok "registered with pgbouncer on prod-homelab$p" || bad "pgbouncer registration on prod-homelab$p"
    done

    # end to end, as the daemon will connect: runtime login, through the VIP
    local n
    n="$(printf "PGPASSWORD='%s' psql 'host=%s port=6432 dbname=homelab user=badips_runtime sslmode=prefer' -tAXc 'SELECT count(*) FROM jailed_ips'\n" "$BADIPS_DB_PASSWORD" "$PGB_VIP" \
          | rsh "$leader" "bash -s" 2>&1 | tr -d '[:space:]')"
    if [[ "$n" =~ ^[0-9]+$ ]]; then ok "the runtime login reads the list through pgbouncer ($n rows)"; else bad "runtime login through pgbouncer: $n"; fi
}

# ============================================================================
# --db-login ALIAS  (post-cutover #61: a legacy host's own login)
# ============================================================================
do_db_login(){
    local alias="$1" role secret leader exists pw scram p n
    load_site
    is_legacy "$alias" && legacy_spec "$alias" >/dev/null || die "--db-login takes a legacy host alias from LEGACY_HOSTS in $SITE (e.g. jumper)"
    [ "$(legacy_role "$alias")" != off ] || die "$alias has role off in LEGACY_HOSTS: an off host uses no database login"
    role="$(db_user_for "$alias")"; secret="$(secret_file_for "$alias")"
    say "$alias: its own login on the shared ban list, $role (a member of badips_runtime: the same rights, revocable alone)"
    leader="$(find_leader)" || die "no Patroni leader among $DB_NODES"
    ok "Patroni leader: prod-homelab$leader"
    rsh "$leader" "sudo -u postgres psql -d homelab -tAXc \"SELECT 1 FROM pg_roles WHERE rolname = 'badips_runtime'\"" | grep -q 1 \
        || die "no login badips_runtime on the database: run --db first"
    exists="$(rsh "$leader" "sudo -u postgres psql -d homelab -tAXc \"SELECT 1 FROM pg_roles WHERE rolname = '$role'\"" | tr -d '[:space:]')"
    if [ "$exists" = 1 ] && [ -f "$secret" ]; then
        load_secret_for "$alias"; pw="$DB_PASS"
        ok "login $role already exists; its password is kept ($secret)"
    else
        [ "$exists" != 1 ] || warn "login $role exists but $secret is missing: giving it a new password (re-run --install $alias afterwards)"
        pw="$(openssl rand -hex 20)"
        # the password travels on stdin, never on a command line
        { printf "DO \$\$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '%s') THEN CREATE ROLE %s LOGIN; END IF; END \$\$;\n" "$role" "$role"
          printf "ALTER ROLE %s PASSWORD '%s';\n" "$role" "$pw"
          printf "ALTER ROLE %s IN DATABASE homelab SET search_path = badips;\n" "$role"
          printf "GRANT badips_runtime TO %s;\n" "$role"; } \
          | rsh "$leader" "sudo -u postgres psql -d homelab -X -q -v ON_ERROR_STOP=1" || die "creating the login failed"
        ( umask 077; printf "# bad-ips shared ban list: %s's OWN login, %s -- a member of badips_runtime (same rights).\n# Revoke it alone with: ALTER ROLE %s NOLOGIN. Written by badips-orchestrate.sh --db-login on %s. Not in git.\nBADIPS_DB_USER='%s'\nBADIPS_DB_PASSWORD='%s'\n" \
            "$alias" "$role" "$role" "$(date -Is)" "$role" "$pw" > "$secret" )
        ok "login $role created as a member of badips_runtime (password saved to $secret)"
    fi
    [ "$(rsh "$leader" "sudo -u postgres psql -d homelab -tAXc \"SELECT pg_has_role('$role', 'badips_runtime', 'MEMBER')\"" | tr -d '[:space:]')" = t ] \
        && ok "$role is a member of badips_runtime" || bad "$role is NOT a member of badips_runtime"
    scram="$(rsh "$leader" "sudo -u postgres psql -d homelab -tAXc \"SELECT rolpassword FROM pg_authid WHERE rolname = '$role'\"" | tr -d '[:space:]')"
    [ -n "$scram" ] || die "could not read $role's SCRAM secret"
    for p in $PGB_NODES; do
        printf "homelab-bootstrap-pgbouncer-entry --role %s --scram-secret '%s' --pgbouncer-host localhost\n" "$role" "$scram" \
            | rsh "$p" "sudo bash -s" >/dev/null 2>&1 && ok "registered with pgbouncer on prod-homelab$p" || bad "pgbouncer registration on prod-homelab$p"
    done
    # end to end, as the host's daemon will connect: its own login, through the VIP, reading and able to report
    n="$(printf "PGPASSWORD='%s' psql 'host=%s port=6432 dbname=homelab user=%s sslmode=prefer' -tAXc 'SELECT count(*) FROM jailed_ips'\n" "$pw" "$PGB_VIP" "$role" \
          | rsh "$leader" "bash -s" 2>&1 | tr -d '[:space:]')"
    if [[ "$n" =~ ^[0-9]+$ ]]; then ok "$role reads the list through pgbouncer ($n rows)"; else bad "$role through pgbouncer: $n"; fi
    [ "$(rsh "$leader" "sudo -u postgres psql -d homelab -tAXc \"SELECT has_table_privilege('$role', 'badips.jailed_ips', 'INSERT')\"" | tr -d '[:space:]')" = t ] \
        && ok "$role can report (INSERT on jailed_ips, inherited)" || bad "$role cannot INSERT on jailed_ips"
}

# ============================================================================
# --proving-ground
# ============================================================================
do_proving_ground(){
    local n; n="$(nn "$PG_NODE")"
    load_site; load_secret
    EXPECT_VERSION="${EXPECT_VERSION:-$(repo_version)}"
    [ -n "$EXPECT_VERSION" ] || die "no bad-ips in $REPO_DIR -- build it first (../../bad-ips/build-package.sh X.Y.Z)"
    case " $EDGES $REPORTERS $DB_NODES $PGB_NODES " in *" $n "*) die "prod-homelab$n is not a spare" ;; esac
    up "$n" || die "prod-homelab$n does not answer"
    say "proving ground on prod-homelab$n: bad-ips $EXPECT_VERSION FROM THE FLEET REPO, block role on a made-up interface, WITH the shared list"
    rsh "$n" "ip link show badipstest0 >/dev/null 2>&1" && die "an interface badipstest0 exists on prod-homelab$n"
    local leader host; leader="$(find_leader)" || die "no Patroni leader among $DB_NODES"
    host="$(rsh "$n" hostname -s)"
    q(){ rsh "$leader" "sudo -u postgres psql -d homelab -tAXc \"$1\"" 2>/dev/null | tr -d '[:space:]'; }
    local TEST_IPS="'203.0.113.250','203.0.113.251'"
    local NBV4 NBSQL; NBV4="$(never_v4 | paste -sd' ')"; NBSQL="$(for e in ${NEVER_BLOCK//,/ }; do printf "'%s'\n" "$e"; done | paste -sd,)"

    local out
    out="$(retire_leftovers "$n")" || { printf '%s\n' "$out" | sed 's/^/    /'; bad "an unknown file where a leftover was expected"; return; }
    [ -n "$out" ] && printf '%s\n' "$out" | sed 's/^/  ok   /'

    { printf '%s\n# PROVING GROUND: block role on a spare node, dropping ONLY on a made-up interface\n' "$HDR"
      printf '# no packet can arrive on, so this node is unaffected. Removed by the same run.\n[global]\n'
      printf 'role = block\ndry_run = 0\nblock_interfaces = badipstest0\nreconcile_interval = 30\n\n'
      printf '[rule:proving-ground]\nsource  = /var/lib/bad_ips/proving-ground.log\nformat  = nginx\n'
      printf 'match   = ^(?<ip>[0-9A-Fa-f.:]+) \\S+ \\S+ \\[[^\\]]+\\] "GET /\\.env\ncount   = 3\nwindow  = 600\nban     = 900\nservice = test\n'
    } | put "$n" "$CONFDIR/94-role.conf" || die "could not write the config"
    conf_fleet | put "$n" "$CONFDIR/95-fleet.conf" || die "could not write the config"
    conf_db    | put "$n" "$CONFDIR/96-fleet-db.conf" || die "could not write the config"

    # 1. A second database file -- a stand-in for the leftover of 2026-11-02 --
    #    must be REFUSED, and the service left OFF, by the package itself.
    printf '# PROVING GROUND stand-in for a leftover database.conf; removed by the same run.\n[global]\ndb_host = 192.0.2.1\ndb_port = 5432\ndb_name = bad_ips\ndb_user = bad_ips\ndb_password = standin\n' \
        | put "$n" "$CONFDIR/database.conf" || die "could not write the stand-in"
    install_pkg "$n" || { bad "install from the repo failed (see /tmp/badips-install.log on the node)"; return; }
    local st why
    st="$(node_status "$n")"
    sfs(){ printf '%s\n' "${st% first_warn=*}" | tr ' ' '\n' | sed -n "s/^$1=//p" | head -1; }
    [ "$(sfs version)" = "$EXPECT_VERSION" ] && ok "installed $EXPECT_VERSION from the fleet repo (apt, through aptcacher)" \
                                             || bad "installed $(sfs version), want $EXPECT_VERSION"
    if [ "$(sfs config)" = REFUSED ] && [ "$(sfs enabled)/$(sfs active)" = disabled/inactive ]; then
        ok "a second database file is refused, and the service is left off"
    else
        bad "a second database file was NOT refused: $st"
    fi
    # captured first: --test-config exits 1 for a refused config (that is the
    # point), and under pipefail a pipe from it would always count as failed
    local tco; tco="$(rsh "$n" "sudo /usr/local/sbin/bad_ips --test-config 2>&1")"
    printf '%s\n' "$tco" | grep -q "come from more than one file: .*96-fleet-db\\.conf .*database\\.conf" \
        && ok "...and --test-config names both files" || bad "--test-config did not name both files"
    rsh "$n" "sudo rm -f $CONFDIR/database.conf && sudo dpkg-reconfigure -f noninteractive bad-ips >/dev/null 2>&1"

    # 2. The real firewall, then the shared list in both directions.
    # A remote helper: wait up to $1 s for the shell test $2; print seconds or "timeout".
    local WAITFN='w(){ local t=0; while [ $t -lt $1 ]; do eval "$2" && { echo $t; return 0; }; sleep 1; t=$((t+1)); done; echo timeout; return 1; }
                  cnt(){ sudo nft -j list set inet badips "$1" 2>/dev/null | jq "[.nftables[] | select(.set) | .set.elem // [] | length] | add // 0"; }
                  inset(){ sudo nft list set inet badips badipv4 2>/dev/null | grep -q "$1"; }'
    out="$(rsh "$n" "NBV4='$NBV4'; $WAITFN"'
        echo "table_after=$(w 30 "sudo nft list table inet badips >/dev/null 2>&1")"
        echo "never4=$(cnt never_block)"; echo "never6=$(cnt never_block_v6)"
        echo "iface_rule=$(sudo nft list chain inet badips preroute_block | grep -c "iifname != \"badipstest0\"")"
        echo "dns_rule=$(sudo nft list chain inet badips preroute_block | grep -c "th dport 53 accept")"
        echo "feed_after=$(w 90 "[ \$(cnt feedv4) -gt 1000 ]")"; echo "feed4=$(cnt feedv4)"; echo "feed6=$(cnt feedv6)"
        TS=$(date -u +%d/%b/%Y:%H:%M:%S\ +0000)
        for i in 1 2 3; do echo "203.0.113.250 - - [$TS] \"GET /.env HTTP/1.1\" 404 162 \"-\" \"proving-ground\"" | sudo tee -a /var/lib/bad_ips/proving-ground.log >/dev/null; done
        echo "ban_after=$(w 15 "inset 203.0.113.250")"
        sudo systemctl reload nftables
        echo "never4_after_reload=$(cnt never_block)"
        echo "ban_back_after_reload=$(w 45 "inset 203.0.113.250")"
        echo "feed_back_after_reload=$(w 45 "[ \$(cnt feedv4) -gt 1000 ]")"
        sudo nft delete table inet badips
        echo "rebuilt_after_delete=$(w 45 "inset 203.0.113.250")"
        echo "never4_after_rebuild=$(cnt never_block)"
        echo "persist_file=$(test -f /etc/nftables.d/99-badips.nft && echo yes || echo no)"
        echo "persist_check=$(sudo nft -c -f /etc/nftables.d/99-badips.nft >/dev/null 2>&1 && echo ok || echo FAIL)"
        echo "base_filter=$(sudo nft list table inet filter >/dev/null 2>&1 && echo present || echo MISSING)"
        # the shared list -> this firewall: a ban made in the list (NOT by this
        # daemon), then lifted
        sudo /usr/local/sbin/bad_ips ban 203.0.113.251 --for 10m --reason proving-ground >/dev/null 2>&1; echo "cli_ban_rc=$?"
        echo "list_to_fw=$(w 75 "inset 203.0.113.251")"
        sudo /usr/local/sbin/bad_ips unban 203.0.113.251 --reason proving-ground >/dev/null 2>&1; echo "cli_unban_rc=$?"
        echo "unban_to_fw=$(w 100 "! inset 203.0.113.251")"
        # the house and offsite (from the site file, never from this script)
        # can never be banned, by hand either: each ban must be refused (rc 1)
        # (rc 1 alone is not proof: a database error is also rc 1 -- the
        # refusal must be the never-block one)
        nb_not_refused=0
        for a in $NBV4; do
            m=$(sudo /usr/local/sbin/bad_ips ban "$a" --for 10m --reason proving-ground 2>&1); rc=$?
            { [ $rc = 1 ] && printf "%s\n" "$m" | grep -q "is on the never-block list"; } || nb_not_refused=$((nb_not_refused + 1))
        done
        echo "never_tried=$(echo $NBV4 | wc -w)"; echo "never_not_refused=$nb_not_refused"
        pid=$(systemctl show -p MainPID --value bad_ips)
        echo "warns=$(sudo grep -cE "^[^|]*\|$pid\|(WARN|ERROR|FATAL)\|" /var/log/bad_ips/bad_ips.log 2>/dev/null)"
    ' 2>&1)"
    printf '%s\n' "$out" | sed 's/^/    /'
    v(){ printf '%s\n' "$out" | sed -n "s/^$1=//p" | head -1; }
    [ "$(v table_after)" != timeout ]          && ok "table built ($(v table_after) s after start)"           || bad "table never appeared"
    st="$(node_status "$n")"
    if why="$(node_check block "$st")"; then ok "exactly as the block role needs: $(node_brief "$st")"; else bad "block role: $why"; fi
    [ "$(v never4)" -gt 5 ] 2>/dev/null         && ok "never-block in place ($(v never4) v4, $(v never6) v6 entries)" || bad "never-block empty"
    [ "$(v iface_rule)" = 1 ]                   && ok "drops only on badipstest0"                              || bad "interface rule missing"
    [ "$(v dns_rule)" = 1 ]                     && ok "DNS accepted ahead of the drops"                        || bad "DNS rule missing"
    [ "$(v feed_after)" != timeout ]            && ok "Spamhaus feed loaded ($(v feed4) v4, $(v feed6) v6 ranges)" || bad "feed not loaded"
    [ "$(v ban_after)" != timeout ]             && ok "a detection was blocked within $(v ban_after) s"        || bad "detection not blocked"
    [ "$(v never4_after_reload)" = "$(v never4)" ] && ok "after an nftables reload, never-block was back at once" || bad "never-block after reload: $(v never4_after_reload)"
    [ "$(v ban_back_after_reload)" != timeout ] && ok "after an nftables reload, the ban was back within $(v ban_back_after_reload) s" || bad "ban not restored after reload"
    [ "$(v feed_back_after_reload)" != timeout ] && ok "after an nftables reload, the feed was back within $(v feed_back_after_reload) s" || bad "feed not restored after reload"
    [ "$(v rebuilt_after_delete)" != timeout ]  && ok "after the table was deleted, it was rebuilt within $(v rebuilt_after_delete) s" || bad "table not rebuilt"
    [ "$(v persist_check)" = ok ]               && ok "the persistent file passes nft -c"                      || bad "persistent file: $(v persist_check)"
    [ "$(v base_filter)" = present ]            && ok "the node's own firewall (inet filter) untouched"        || bad "inet filter missing!"
    local det; det="$(q "SELECT count(*) FROM badips.jailed_ips WHERE ip = '203.0.113.250' AND originating_server = '$host' AND detector_name = 'proving-ground'")"
    [ "$det" = 1 ]                              && ok "the detection here reached the shared list (as $host / proving-ground)" || bad "detection not in the shared list ($det rows)"
    [ "$(v cli_ban_rc)" = 0 ] && [ "$(v list_to_fw)" != timeout ] \
                                                && ok "a ban made in the shared list was blocked here within $(v list_to_fw) s" || bad "a ban in the shared list did not reach this firewall (rc $(v cli_ban_rc), $(v list_to_fw))"
    [ "$(v cli_unban_rc)" = 0 ] && [ "$(v unban_to_fw)" != timeout ] \
                                                && ok "an unban lifted it here within $(v unban_to_fw) s"      || bad "unban not applied (rc $(v cli_unban_rc), $(v unban_to_fw))"
    [ "$(v never_tried)" -ge 2 ] 2>/dev/null && [ "$(v never_not_refused)" = 0 ] \
                                                && ok "banning the house or offsite by hand is refused ($(v never_tried) never-block networks tried)" || bad "never-block NOT enforced by hand ($(v never_not_refused) of $(v never_tried) bans went through)"
    local nb; nb="$(q "SELECT count(*) FROM badips.jailed_ips WHERE ip && ANY (ARRAY[$NBSQL]::inet[])")"
    [ "$nb" = 0 ]                               && ok "...and neither is in the shared list"                    || bad "never-block address in the shared list ($nb rows)"
    [ "$(v warns)" = 0 ]                        && ok "no warnings or errors from the daemon all run"          || bad "$(v warns) warning/error lines in /var/log/bad_ips/bad_ips.log from this daemon"

    say "putting prod-homelab$n back to role off, and removing its test rows"
    conf_role off | put "$n" "$CONFDIR/94-role.conf"
    rsh "$n" "sudo rm -f $CONFDIR/96-fleet-db.conf /var/lib/bad_ips/proving-ground.log; sudo dpkg-reconfigure -f noninteractive bad-ips >/dev/null 2>&1"
    st="$(node_status "$n")"
    if why="$(node_check off "$st")"; then ok "back to off: $(node_brief "$st")"; else bad "after switching off: $why"; fi
    rsh "$n" "test -f /etc/nftables.d/99-badips.nft" && bad "persistent file still present" || ok "persistent file removed"
    q "DELETE FROM badips.jailed_ips WHERE ip IN ($TEST_IPS); DELETE FROM badips.exemptions WHERE ip IN ($TEST_IPS)" >/dev/null
    local left; left="$(q "SELECT (SELECT count(*) FROM badips.jailed_ips WHERE ip IN ($TEST_IPS)) + (SELECT count(*) FROM badips.exemptions WHERE ip IN ($TEST_IPS))")"
    [ "$left" = 0 ] && ok "test rows removed from the shared list" || bad "$left test row(s) left in the shared list"
}

# ============================================================================
# --install / --role / --verify / --static-realip
# ============================================================================
# One per line: nn() prints no newline, and run together the numbers made ONE
# bogus node "000102...72" (found in the first --rollout, 2026-11-02).
all_nodes(){ local i; for i in $(seq "$FIRST" "$LAST"); do printf '%02d\n' "$i"; done; }

do_install(){
    local deb="$1"; shift
    load_site; load_secret
    EXPECT_VERSION="${EXPECT_VERSION:-$(repo_version)}"
    local nodes=("$@"); [ ${#nodes[@]} -eq 0 ] && mapfile -t nodes < <(all_nodes)
    say "installing bad-ips ${EXPECT_VERSION:-?} from the fleet repo on ${#nodes[@]} node(s), $PAR at a time -- stopping after any batch with a problem"
    local tmp; tmp="$(mktemp -d)"
    one(){
        local n role log st why; n="$(nn "$1")"; role="$(role_for "$n")"; log="$tmp/$n.log"
        if ! up "$n"; then echo unreachable > "$tmp/$n"; return; fi
        if ! write_config "$n" "$role" >"$log" 2>&1; then
            echo "FAILED writing the config: $(grep -v '^removed' "$log" | paste -sd' ')" > "$tmp/$n"; return
        fi
        if is_legacy "$n" && ! fleet_repo_on "$n" >>"$log" 2>&1; then
            echo "FAILED switching apt to the fleet repo: $(tail -1 "$log")" > "$tmp/$n"; return
        fi
        if ! install_pkg "$n" "$deb" >>"$log" 2>&1; then
            echo "FAILED installing (see /tmp/badips-install.log on the node)" > "$tmp/$n"; return
        fi
        st="$(node_status "$n")"
        if why="$(node_check "$role" "$st" "$(db_user_for "$n")")"; then echo "ok|$(node_brief "$st")" > "$tmp/$n"; else echo "WRONG: $why" > "$tmp/$n"; fi
    }
    report(){
        local n r role lo rs
        for n in "$@"; do
            n="$(nn "$n")"; role="$(role_for "$n")"; r="$(cat "$tmp/$n" 2>/dev/null || echo 'no result')"
            lo="$(grep -c '^removed the known leftover' "$tmp/$n.log" 2>/dev/null)"; lo="${lo:-0}"
            rs="$(grep -E '^(restored shipped file|removed the old 3.x repo|added the fleet repo)' "$tmp/$n.log" 2>/dev/null | paste -sd';' | sed 's/;/; /g')"
            case "$r" in
                unreachable) case " $EDGES " in *" $n "*) warn "$(label "$n"): powered off (parked edge) -- done in the rotation pass" ;;
                                               *) bad "$(label "$n"): unreachable" ;; esac ;;
                ok\|*)       ok  "$(label "$n") ($role): ${r#ok|}$([ "$lo" -gt 0 ] && echo "; removed $lo leftover file(s)")${rs:+; $rs}" ;;
                *)           bad "$(label "$n") ($role): $r" ;;
            esac
        done
    }
    local batch=() n
    for n in "${nodes[@]}"; do
        one "$n" &
        batch+=("$n")
        if [ ${#batch[@]} -ge "$PAR" ]; then
            wait; report "${batch[@]}"; batch=()
            [ "$FAILS" -eq 0 ] || { echo "  ${R}stopped: the nodes after this batch were not touched${O}"; rm -rf "$tmp"; return; }
        fi
    done
    wait
    [ ${#batch[@]} -eq 0 ] || report "${batch[@]}"
    rm -rf "$tmp"
}

do_role(){
    local n role; n="$(nn "$1")"; role="$2"
    case "$role" in block|watch|report|off) ;; *) die "role must be block, watch, report or off" ;; esac
    load_site; [ "$role" = off ] || load_secret_for "$n"
    case "$role" in block|watch) [ -n "$(ifaces_for "$n")" ] || die "$(label "$n") has no block interfaces (LEGACY_HOSTS: alias=block:eth1,...)" ;; esac
    say "$(label "$n") -> $role"
    write_config "$n" "$role" || die "could not write the config"
    rsh "$n" "sudo dpkg-reconfigure -f noninteractive bad-ips" >/dev/null 2>&1 || bad "dpkg-reconfigure"
    local st why; st="$(node_status "$n")"
    if why="$(node_check "$role" "$st" "$(db_user_for "$n")")"; then ok "$(node_brief "$st")"; else bad "$(label "$n"): $why"; fi
}

# --upgrade: the package only, on nodes that have it, roles untouched. The
# postinst keeps whatever 94-role.conf says, so a blocking edge keeps blocking
# (--install would rewrite it to watch: the item 43 trap). Stops at the first
# node that is not right afterwards.
do_upgrade(){
    local nodes=("$@"); [ ${#nodes[@]} -eq 0 ] && mapfile -t nodes < <(all_nodes)
    load_site
    EXPECT_VERSION="${EXPECT_VERSION:-$(repo_version)}"
    say "bad-ips ${EXPECT_VERSION:-?}: upgrading the package where it is installed (${#nodes[@]} target(s)), roles untouched"
    local n v st want why r
    for n in "${nodes[@]}"; do
        n="$(nn "$n")"
        if ! up "$n"; then case " $EDGES " in *" $n "*) warn "$(label "$n"): powered off (parked edge) -- upgraded in the rotation pass" ;; *) bad "$(label "$n"): unreachable" ;; esac; continue; fi
        v="$(rsh "$n" "dpkg-query -W -f='\${Version}' bad-ips 2>/dev/null")"
        [ -n "$v" ] || { warn "$(label "$n"): bad-ips not installed -- skipped"; continue; }
        if [ "$v" = "$EXPECT_VERSION" ]; then ok "$(label "$n"): already $v"; continue; fi
        rsh "$n" "sudo apt-get update -qq >/tmp/badips-upgrade.log 2>&1; sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q --only-upgrade bad-ips >>/tmp/badips-upgrade.log 2>&1" \
            || { bad "$(label "$n"): the upgrade failed (see /tmp/badips-upgrade.log there); stopping"; return; }
        st="$(node_status "$n")"; want="$(role_for "$n")"
        if is_block_host "$n"; then r="$(printf '%s\n' "$st" | tr ' ' '\n' | sed -n 's/^role=//p')"; case "$r" in block|watch) want="$r" ;; esac; fi
        if why="$(node_check "$want" "$st" "$(db_user_for "$n")")"; then ok "$(label "$n") ($want): $v -> $(node_brief "$st")"
        else bad "$(label "$n") ($want): $why"; echo "  ${R}stopped: the targets after this one were not touched${O}"; return; fi
    done
}

do_verify(){
    local nodes=("$@"); [ ${#nodes[@]} -eq 0 ] && mapfile -t nodes < <(all_nodes)
    load_site                                           # roles of legacy targets
    EXPECT_VERSION="${EXPECT_VERSION:-$(repo_version)}"
    say "bad-ips ${EXPECT_VERSION:-?} on ${#nodes[@]} node(s), each against what its role needs"
    local n st want why r
    for n in "${nodes[@]}"; do
        n="$(nn "$n")"
        if ! up "$n"; then case " $EDGES " in *" $n "*) warn "$(label "$n"): powered off (parked edge)" ;; *) bad "$(label "$n"): unreachable" ;; esac; continue; fi
        st="$(node_status "$n")"; want="$(role_for "$n")"
        # a block host (an edge, or a legacy block host) may be watching or blocking (--role X block switches it)
        if is_block_host "$n"; then r="$(printf '%s\n' "$st" | tr ' ' '\n' | sed -n 's/^role=//p')"; case "$r" in block|watch) want="$r" ;; esac; fi
        if why="$(node_check "$want" "$st" "$(db_user_for "$n")")"; then ok "$(label "$n") ($want): $(node_brief "$st")"; else bad "$(label "$n") ($want): $why"; fi
        if is_block_host "$n"; then
            rsh "$n" 'sudo nft list table inet badips >/dev/null 2>&1 && command -v jq >/dev/null || exit 0
                      c(){ sudo nft -j list set inet badips "$1" 2>/dev/null | jq "[.nftables[] | select(.set) | .set.elem // [] | length] | add // 0"; }
                      echo "    blocking: $(c badipv4) addresses, $(c feedv4) + $(c feedv6) feed ranges; never-block $(c never_block) + $(c never_block_v6)"
                      sudo nft list chain inet badips preroute_block 2>/dev/null | grep -E "counter packets [1-9]" | sed "s/^\s*/    drops: /"'
            # what a WATCHING block host would block (on a blocking one that line is stale)
            [ "$want" = watch ] && rsh "$n" 'sudo grep "watch mode: would block" /var/log/bad_ips/bad_ips.log 2>/dev/null | tail -1 | cut -d"|" -f1,6- | sed "s/^/    /"'
        fi
    done
    local leader; leader="$(find_leader)" && \
        printf '  shared list: %s active bans\n' "$(rsh "$leader" "sudo -u postgres psql -d homelab -tAXc \"SELECT count(DISTINCT ip) FROM badips.jailed_ips WHERE expires_at > extract(epoch FROM now())\"" 2>/dev/null | tr -d '[:space:]')"
}

do_static_realip(){
    local n; n="$(nn "$STATIC_NODE")"
    [ -f "$REALIP_CONF" ] || die "missing $REALIP_CONF"
    say "prod-homelab$n: nginx logs the real visitor"
    rsh "$n" "sudo sh -c 'cat > /etc/nginx/conf.d/real-ip-from-edge.conf.new'" < "$REALIP_CONF" || die "copy failed"
    if rsh "$n" "sudo mv -f /etc/nginx/conf.d/real-ip-from-edge.conf.new /etc/nginx/conf.d/real-ip-from-edge.conf && sudo chmod 0644 /etc/nginx/conf.d/real-ip-from-edge.conf && sudo nginx -t >/dev/null 2>&1"; then
        rsh "$n" "sudo systemctl reload nginx" && ok "installed /etc/nginx/conf.d/real-ip-from-edge.conf; nginx reloaded"
    else
        rsh "$n" "sudo rm -f /etc/nginx/conf.d/real-ip-from-edge.conf"
        bad "nginx -t failed with it; removed again, nginx untouched"
    fi
}


# ============================================================================
# --deploy-web
# ============================================================================
WEB_PKGS="homelab-common homelab-api homelab-sso homelab-roundcube homelab-webproxy"
deploy_node(){ # NN -> prints a status line; returns non-zero on a problem
    rsh "$1" "
        export DEBIAN_FRONTEND=noninteractive NEEDRESTART_SUSPEND=1
        sudo -E apt-get update -qq >/tmp/badips-deploy-web.log 2>&1 || { echo 'apt-get update failed'; exit 1; }
        before=\$(dpkg-query -W -f='\${Package}=\${Version} ' $WEB_PKGS 2>/dev/null)
        sudo -E apt-get install -y -qq --only-upgrade $WEB_PKGS >>/tmp/badips-deploy-web.log 2>&1 || { echo 'upgrade failed (see /tmp/badips-deploy-web.log)'; exit 1; }
        after=\$(dpkg-query -W -f='\${Package}=\${Version} ' $WEB_PKGS 2>/dev/null)
        r=''
        # nothing upgraded (already current, e.g. a re-run): no restarts
        [ \"\$before\" = \"\$after\" ] && { echo \"\$(echo \$after | sed 's/homelab-//g') | already current, nothing restarted\"; exit 0; }
        for u in \$(systemctl list-units 'homelab-*' --type=service --state=running --no-legend | awk '{print \$1}'); do
            systemctl cat \"\$u\" 2>/dev/null | grep -q '^ExecStart=/usr/bin/hypnotoad' || continue
            sudo systemctl restart \"\$u\" && r=\"\$r \${u%.service}\"
        done
        sleep 6
        bad=''
        for u in \$r; do systemctl is-active --quiet \"\$u\" || bad=\"\$bad \$u\"; done
        f=\$(systemctl list-units 'homelab-*' --state=failed --no-legend | awk '{print \$1}' | paste -sd' ')
        v=\$(dpkg-query -W -f='\${Package}=\${Version} ' $WEB_PKGS 2>/dev/null | sed 's/homelab-//g')
        echo \"\$v| restarted:\${r:- none}\${bad:+ | NOT ACTIVE:\$bad}\${f:+ | FAILED UNITS: \$f}\"
        [ -z \"\$bad\" ] && [ -z \"\$f\" ]
    " 2>/dev/null
}

do_deploy_web(){
    local order=() seen=" " n live
    for n in 12 13 14 18 19 20 42 43 44; do order+=("$n"); seen="$seen$n "; done
    for n in $EDGES; do up "$n" && { order+=("$n"); seen="$seen$n "; live="$n"; }; done
    for n in $(all_nodes); do case "$seen" in *" $n "*) ;; *) order+=("$n") ;; esac; done
    say "deploying the real-visitor fixes, one node at a time (${#order[@]} nodes)"
    local out
    for n in "${order[@]}"; do
        if ! up "$n"; then
            case " $EDGES " in *" $n "*) warn "prod-homelab$n: parked edge -- upgraded when rotated in (edge-rotate.sh)" ;;
                               *) warn "prod-homelab$n: unreachable -- skipped" ;; esac
            continue
        fi
        if out="$(deploy_node "$n")"; then
            ok "prod-homelab$n: $out"
        else
            bad "prod-homelab$n: ${out:-no answer}"
            echo "  stopping here: fix prod-homelab$n first, then re-run (finished nodes are skipped quickly)"
            return
        fi
    done
    [ -n "${live:-}" ] && echo "  ${Y}check the edge from offsite:${O} ssh offsite and run edge-verify.sh's public checks"
}

# ============================================================================
# --publish / --rollout
# ============================================================================
REPO_DIR="$HOME/apt-repo-homelab"
REPO_HOST=10.20.2.189                                   # prod-homelab45
REPO_PATH=/var/www/projects.thedude.vip/apt-homelab/

do_publish(){ # [DEB] -- the fleet repo as built (build-package.sh), plus DEB if given
    local deb="${1:-}" v
    if [ -n "$deb" ]; then
        v="$(dpkg-deb -f "$deb" Version 2>/dev/null)" || die "cannot read $deb"
        if reprepro -b "$REPO_DIR" list unstable bad-ips 2>/dev/null | grep -q " $v\$"; then
            ok "bad-ips $v is already in $REPO_DIR"
        else
            reprepro -b "$REPO_DIR" includedeb unstable "$deb" >/tmp/badips-publish.log 2>&1 \
                && ok "added $(basename "$deb") to $REPO_DIR" || { bad "reprepro includedeb failed (see /tmp/badips-publish.log)"; return; }
        fi
    fi
    v="$(repo_version)"; [ -n "$v" ] || die "no bad-ips in $REPO_DIR -- build it first (../../bad-ips/build-package.sh X.Y.Z)"
    say "publishing the fleet repo (bad-ips $v, and every package already built into it) to prod-homelab45"
    rsync -rlq "$REPO_DIR/" "$REPO_HOST:$REPO_PATH" --exclude=conf --exclude=db --exclude=vendor --exclude=REPREPRO.md \
          --exclude='*.pem' --exclude='id_rsa*' --exclude='*_rsa' --exclude='secring*' \
        && ok "published to prod-homelab45" || { bad "rsync to prod-homelab45 failed"; return; }
    [ -d "$TOP/../bad-ips/git/website" ] && rsync -rlq "$TOP/../bad-ips/git/website/" "$REPO_HOST:/var/www/projects.thedude.vip/bad-ips/" 2>/dev/null
    # what the FLEET sees -- asked of apt on a fleet node, through the same
    # cache (aptcacher) every install will go through
    local cand
    cand="$(rsh 12 "sudo apt-get update -qq >/dev/null 2>&1; apt-cache policy bad-ips | awk '/Candidate:/{print \$2}'" 2>/dev/null)"
    if [ "$cand" = "$v" ]; then ok "the fleet's apt (through aptcacher) now offers bad-ips $v"
    else bad "the fleet's apt offers bad-ips '${cand:-nothing}', not $v (a stale aptcacher index?)"; fi
}

# every node in all_nodes that is not a canary
rest_nodes(){ local n; for n in $(all_nodes); do case " $CANARIES " in *" $((10#$n)) "*|*" $n "*) ;; *) echo "$n" ;; esac; done; }

do_continue(){
    EXPECT_VERSION="${EXPECT_VERSION:-$(repo_version)}"
    do_deploy_web;                     [ "$FAILS" -eq 0 ] || { echo; echo "${R}stopped during the web deploy${O}"; return; }
    # shellcheck disable=SC2086
    do_install "" $CANARIES;           [ "$FAILS" -eq 0 ] || { echo; echo "${R}stopped at the canaries${O}"; return; }
    do_install "" $(rest_nodes);       [ "$FAILS" -eq 0 ] || { echo; echo "${R}stopped while installing${O}"; return; }
    do_static_realip;                  [ "$FAILS" -eq 0 ] || { echo; echo "${R}stopped at the static host${O}"; return; }
    say "parked edge nodes: base firewall (closes SSH) and bad-ips config"
    "$HERE/edge-standby-sync.sh" 2>&1 | sed 's/^/  /'; [ "${PIPESTATUS[0]}" -eq 0 ] || FAILS=$((FAILS + 1))
    [ "$FAILS" -eq 0 ] && do_verify
}

do_rollout(){
    do_publish "${1:-}";       [ "$FAILS" -eq 0 ] || { echo; echo "${R}stopped after publishing${O}"; return; }
    do_proving_ground;         [ "$FAILS" -eq 0 ] || { echo; echo "${R}stopped after the proving ground${O}"; return; }
    do_db;                     [ "$FAILS" -eq 0 ] || { echo; echo "${R}stopped after the database step${O}"; return; }
    do_continue
}

# ============================================================================
cmd="${1:-}"; shift || true
DEB=""
args=()
while [ $# -gt 0 ]; do
    case "$1" in
        --deb) DEB="${2:-}"; shift 2 ;;
        *) args+=("$1"); shift ;;
    esac
done
# every target must be a node number or a legacy alias from LEGACY_HOSTS
check_targets(){ local a; load_site; for a in "$@"; do is_legacy "$a" && { legacy_spec "$a" >/dev/null || die "'$a' is neither a node number nor an alias in LEGACY_HOSTS ($SITE)"; }; done; }
case "$cmd" in --install|--verify|--upgrade) check_targets "${args[@]}" ;; --role|--print-config|--db-login) [ ${#args[@]} -ge 1 ] && check_targets "${args[0]}" ;; esac
case "$cmd" in
    --db)             do_db ;;
    --grafana-db)     do_grafana_db ;;
    --api-grants)     do_api_grants ;;
    --proving-ground) do_proving_ground ;;
    --install)        do_install "$DEB" "${args[@]}" ;;
    --db-login)       [ ${#args[@]} -eq 1 ] || die "usage: --db-login ALIAS"; do_db_login "${args[0]}" ;;
    --role)           [ ${#args[@]} -eq 2 ] || die "usage: --role NN|ALIAS block|watch|report|off"; do_role "${args[0]}" "${args[1]}" ;;
    --verify)         do_verify "${args[@]}" ;;
    --upgrade)        do_upgrade "${args[@]}" ;;
    --static-realip)  do_static_realip ;;
    --deploy-web)     do_deploy_web ;;
    --publish)        do_publish "$DEB" ;;
    --rollout)        do_rollout "$DEB" ;;
    --continue)       do_continue ;;
    --print-config)   [ ${#args[@]} -eq 1 ] || die "usage: --print-config NN|ALIAS"
                      load_site; t="$(nn "${args[0]}")"; name=''; is_legacy "$t" && name="$t"
                      r="$(role_for "$t")"; DB_USER="$(db_user_for "$t")"; DB_PASS='********'
                      echo "### $(label "$t"): role $r"
                      echo "### $CONFDIR/94-role.conf";  conf_role "$r" "$(ifaces_for "$t")" "$name"
                      echo "### $CONFDIR/95-fleet.conf"; conf_fleet
                      [ "$r" = off ] && echo "### (no 96-fleet-db.conf: role off does not use the database)" \
                                     || { echo "### $CONFDIR/96-fleet-db.conf"; conf_db; }
                      exit 0 ;;
    *) awk 'NR>2 && /^# ====/{exit} NR>2{sub(/^# ?/, ""); print}' "$0"; exit 2 ;;
esac
echo
[ "$FAILS" -eq 0 ] && printf '%sdone, no failures%s\n' "$G" "$O" || printf '%s%d failure(s)%s\n' "$R" "$FAILS" "$O"
[ "$FAILS" -eq 0 ]
