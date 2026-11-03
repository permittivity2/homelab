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
#   ./badips-orchestrate.sh --verify [NN ...]
#       read-only: every node against node_check (version, role, files,
#       database and whether the daemon itself connected to it, service,
#       firewall table); the edge's ban/feed counts; the shared list's count.
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
#   ./badips-orchestrate.sh --print-config NN
#       print the files node NN would get (password masked); changes nothing.
#
# Roles: edge 00/01/02 -> watch on first install (reports, blocks nothing;
#        switch on with --role 00 block); postfix 39/40/41 and dovecot VMs
#        62/63/64 -> report; every other node -> off (installed, switched off).
#
# Site values -- the never-block list for the house and offsite -- come from
# ../../badips-site.conf, NOT from git (both repos are public). The shared
# list's runtime password lives in ../../badips-db.secret (written by --db,
# mode 600). The script refuses to run without them.
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
61ed4a90073312dea0fd1eafb0099a782ec831516ee0b1ad3a79e9b7fb772a4d:/usr/local/etc/badips.d/database.conf"

G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; B=$'\033[1m'; O=$'\033[0m'
FAILS=0
say(){ printf '\n%s== %s ==%s\n' "$B" "$*" "$O"; }
ok(){ printf '  %sok%s   %s\n' "$G" "$O" "$*"; }
bad(){ printf '  %sFAIL%s %s\n' "$R" "$O" "$*"; FAILS=$((FAILS + 1)); }
warn(){ printf '  %swarn%s %s\n' "$Y" "$O" "$*"; }
die(){ printf '%sERROR:%s %s\n' "$R" "$O" "$*" >&2; exit 2; }

ip_of(){ printf '10.20.2.%d' "$((144 + 10#$1))"; }
rsh(){ local n="$1"; shift; ssh -o BatchMode=yes -o ConnectTimeout=6 -o StrictHostKeyChecking=accept-new "$(ip_of "$n")" "$@"; }
up(){ timeout 12 ssh -o BatchMode=yes -o ConnectTimeout=5 "$(ip_of "$1")" true 2>/dev/null; }
nn(){ printf '%02d' "$((10#$1))"; }

role_for(){
    case " $EDGES " in *" $1 "*) echo watch; return ;; esac
    case " $REPORTERS " in *" $1 "*) echo report; return ;; esac
    echo off
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
conf_role(){
    printf '%s\n[global]\n' "$HDR"
    case "$1" in
        watch)  printf '# The edge, in WATCH mode: detects and reports, blocks nothing.\nrole = block\ndry_run = 1\nblock_interfaces = eth6, eth7\n' ;;
        block)  printf '# The edge: drops shared-list and feed addresses, on its two internet-facing interfaces only.\nrole = block\ndry_run = 0\nblock_interfaces = eth6, eth7\n' ;;
        report) printf '# Reports attackers to the shared ban list; never blocks.\nrole = report\n' ;;
        off)    printf '# Installed and configured, switched off.\nrole = off\n' ;;
    esac
}
conf_fleet(){
    printf '%s\n# Identical on every node.\n[global]\nnever_block_cidrs = %s\n' "$HDR" "$NEVER_BLOCK"
}
conf_db(){
    printf '%s\n# The shared ban list, through the pgbouncer VIP. Only on nodes whose role uses it.\n[global]\n' "$HDR"
    printf 'db_host = %s\ndb_port = 6432\ndb_name = homelab\ndb_user = badips_runtime\ndb_password = %s\ndb_schema = badips\n' \
        "$PGB_VIP" "$BADIPS_DB_PASSWORD"
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
rc=0
for e in $LEFTOVERS; do
    h=${e%%:*}; f=${e#*:}
    [ -e "$f" ] || continue
    if [ -f "$f" ] && [ "$(sha256sum < "$f" | cut -d' ' -f1)" = "$h" ]; then
        rm -f "$f" && echo "removed the known leftover $f"
    else
        echo "UNKNOWN $f: not the known leftover -- left alone, look at it"; rc=1
    fi
done
exit $rc
EOS
    } | rsh "$1" "sudo bash -s"
}

write_config(){ # NN ROLE
    local n="$1" role="$2"
    retire_leftovers "$n" || return 1
    conf_role "$role" | put "$n" "$CONFDIR/94-role.conf" || return 1
    conf_fleet       | put "$n" "$CONFDIR/95-fleet.conf" || return 1
    if [ "$role" = off ]; then
        rsh "$n" "sudo rm -f $CONFDIR/96-fleet-db.conf" || return 1
    else
        conf_db | put "$n" "$CONFDIR/96-fleet-db.conf" || return 1
    fi
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
        rsh "$n" "sudo apt-get update -qq >/tmp/badips-install.log 2>&1; sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q bad-ips >>/tmp/badips-install.log 2>&1 \
                  && sudo dpkg-reconfigure -f noninteractive bad-ips >>/tmp/badips-install.log 2>&1"
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
conn=-; warns=-; first=
L=/var/log/bad_ips/bad_ips.log
if [ "$a" = active ]; then
    pid=$(systemctl show -p MainPID --value bad_ips)
    if [ "$db" != none ]; then
        for i in $(seq 1 30); do grep -q "^[^|]*|$pid|INFO|.*shared ban list: connected to " $L 2>/dev/null && break; sleep 1; done
    fi
    conn=$(grep "^[^|]*|$pid|INFO|.*shared ban list: connected to " $L 2>/dev/null | tail -1 | sed 's/.*connected to //')
    [ -n "$conn" ] || conn=NO
    warns=$(grep -cE "^[^|]*\|$pid\|(WARN|ERROR|FATAL)\|" $L 2>/dev/null)
    first=$(grep -E "^[^|]*\|$pid\|(WARN|ERROR|FATAL)\|" $L 2>/dev/null | head -1 | cut -d'|' -f6- | cut -c1-200)
fi
echo "version=$v role=${r:-?} config=$([ "$tcrc" = 0 ] && echo ok || echo REFUSED) db=${db:-?} reach=${reach:--} daemon_db=$conn warns=$warns enabled=${e:-?} active=${a:-?} table=$t mainconf=$main files=${files:-none} first_warn=$first"
EOS
}

# node_check WANT STATUS -> nothing and 0 when a node is exactly what its
# role needs; else the problems and 1. The ONE definition of "right".
node_check(){
    local want="$1" st="$2" p=() x files expect fleet="badips_runtime@$PGB_VIP:6432/homelab"
    sf(){ printf '%s\n' "${st% first_warn=*}" | tr ' ' '\n' | sed -n "s/^$1=//p" | head -1; }
    [ "$st" = unreachable ] && { echo unreachable; return 1; }
    [ -z "$EXPECT_VERSION" ] || [ "$(sf version)" = "$EXPECT_VERSION" ] || p+=("version $(sf version), want $EXPECT_VERSION")
    [ "$(sf config)" = ok ]       || p+=("configuration REFUSED (sudo bad_ips --test-config says why)")
    [ "$(sf role)" = "$want" ]    || p+=("role $(sf role), want $want")
    [ "$(sf mainconf)" = absent ] || p+=("/usr/local/etc/badips.conf present")
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
        if ! install_pkg "$n" "$deb" >>"$log" 2>&1; then
            echo "FAILED installing (see /tmp/badips-install.log on the node)" > "$tmp/$n"; return
        fi
        st="$(node_status "$n")"
        if why="$(node_check "$role" "$st")"; then echo "ok|$(node_brief "$st")" > "$tmp/$n"; else echo "WRONG: $why" > "$tmp/$n"; fi
    }
    report(){
        local n r role lo
        for n in "$@"; do
            n="$(nn "$n")"; role="$(role_for "$n")"; r="$(cat "$tmp/$n" 2>/dev/null || echo 'no result')"
            lo="$(grep -c '^removed the known leftover' "$tmp/$n.log" 2>/dev/null)"; lo="${lo:-0}"
            case "$r" in
                unreachable) case " $EDGES " in *" $n "*) warn "prod-homelab$n: powered off (parked edge) -- done in the rotation pass" ;;
                                               *) bad "prod-homelab$n: unreachable" ;; esac ;;
                ok\|*)       ok  "prod-homelab$n ($role): ${r#ok|}$([ "$lo" -gt 0 ] && echo "; removed $lo leftover file(s)")" ;;
                *)           bad "prod-homelab$n ($role): $r" ;;
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
    load_site; [ "$role" = off ] || load_secret
    say "prod-homelab$n -> $role"
    write_config "$n" "$role" || die "could not write the config"
    rsh "$n" "sudo dpkg-reconfigure -f noninteractive bad-ips" >/dev/null 2>&1 || bad "dpkg-reconfigure"
    local st why; st="$(node_status "$n")"
    if why="$(node_check "$role" "$st")"; then ok "$(node_brief "$st")"; else bad "prod-homelab$n: $why"; fi
}

do_verify(){
    local nodes=("$@"); [ ${#nodes[@]} -eq 0 ] && mapfile -t nodes < <(all_nodes)
    EXPECT_VERSION="${EXPECT_VERSION:-$(repo_version)}"
    say "bad-ips ${EXPECT_VERSION:-?} on ${#nodes[@]} node(s), each against what its role needs"
    local n st want why r
    for n in "${nodes[@]}"; do
        n="$(nn "$n")"
        if ! up "$n"; then case " $EDGES " in *" $n "*) warn "prod-homelab$n: powered off (parked edge)" ;; *) bad "prod-homelab$n: unreachable" ;; esac; continue; fi
        st="$(node_status "$n")"; want="$(role_for "$n")"
        # an edge may be watching or blocking (--role NN block switches it)
        case " $EDGES " in *" $n "*) r="$(printf '%s\n' "$st" | tr ' ' '\n' | sed -n 's/^role=//p')"; case "$r" in block|watch) want="$r" ;; esac ;; esac
        if why="$(node_check "$want" "$st")"; then ok "prod-homelab$n ($want): $(node_brief "$st")"; else bad "prod-homelab$n ($want): $why"; fi
        case " $EDGES " in *" $n "*)
            rsh "$n" 'sudo nft list table inet badips >/dev/null 2>&1 && command -v jq >/dev/null || exit 0
                      c(){ sudo nft -j list set inet badips "$1" 2>/dev/null | jq "[.nftables[] | select(.set) | .set.elem // [] | length] | add // 0"; }
                      echo "    blocking: $(c badipv4) addresses, $(c feedv4) + $(c feedv6) feed ranges; never-block $(c never_block) + $(c never_block_v6)"
                      sudo nft list chain inet badips preroute_block 2>/dev/null | grep -E "counter packets [1-9]" | sed "s/^\s*/    drops: /"'
            rsh "$n" 'sudo grep "watch mode: would block" /var/log/bad_ips/bad_ips.log 2>/dev/null | tail -1 | cut -d"|" -f1,6- | sed "s/^/    /"' ;;
        esac
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
case "$cmd" in
    --db)             do_db ;;
    --proving-ground) do_proving_ground ;;
    --install)        do_install "$DEB" "${args[@]}" ;;
    --role)           [ ${#args[@]} -eq 2 ] || die "usage: --role NN block|watch|report|off"; do_role "${args[0]}" "${args[1]}" ;;
    --verify)         do_verify "${args[@]}" ;;
    --static-realip)  do_static_realip ;;
    --deploy-web)     do_deploy_web ;;
    --publish)        do_publish "$DEB" ;;
    --rollout)        do_rollout "$DEB" ;;
    --continue)       do_continue ;;
    --print-config)   [ ${#args[@]} -eq 1 ] || die "usage: --print-config NN"
                      load_site; BADIPS_DB_PASSWORD='********'
                      r="$(role_for "$(nn "${args[0]}")")"
                      echo "### prod-homelab$(nn "${args[0]}"): role $r"
                      echo "### $CONFDIR/94-role.conf";  conf_role "$r"
                      echo "### $CONFDIR/95-fleet.conf"; conf_fleet
                      [ "$r" = off ] && echo "### (no 96-fleet-db.conf: role off does not use the database)" \
                                     || { echo "### $CONFDIR/96-fleet-db.conf"; conf_db; }
                      exit 0 ;;
    *) awk 'NR>2 && /^# ====/{exit} NR>2{sub(/^# ?/, ""); print}' "$0"; exit 2 ;;
esac
echo
[ "$FAILS" -eq 0 ] && printf '%sdone, no failures%s\n' "$G" "$O" || printf '%s%d failure(s)%s\n' "$R" "$FAILS" "$O"
[ "$FAILS" -eq 0 ]
