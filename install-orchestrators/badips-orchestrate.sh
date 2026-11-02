#!/bin/bash
# ============================================================================
# bad-ips across the fleet (post-cutover item 33) -- RUN ON THE ADMIN
# WORKSTATION. Every step is workstation -> node over ssh; no node ever ssh's
# to another (the fleet's no-guest-to-guest-trust rule).
#
#   ./badips-orchestrate.sh --db
#       once: the shared ban list's login + schema in the fleet database, and
#       the login registered with pgbouncer 09/10/11. Safe to re-run: an
#       existing login keeps its password (resetting it would break every
#       node's config and pgbouncer's entry at once).
#   ./badips-orchestrate.sh --proving-ground --deb FILE
#       node 47 (a spare; PG_NODE=NN to pick another): installs FILE in the
#       block role dropping ONLY on a made-up interface no packet can arrive
#       on, then tests the real firewall: table built, never-block present, a
#       ban lands, an nftables reload and a deleted table both repaired (and
#       how fast). Then puts the node back to role off and checks the table is
#       gone. Touches nothing else.
#   ./badips-orchestrate.sh --install [NN ...] [--deb FILE]
#       config + package on every node (default: every node 00-72 that
#       answers; parked edge nodes are reported and done in the rotation pass).
#   ./badips-orchestrate.sh --role NN ROLE
#       ROLE = block | watch | report | off   (watch = block, firewall untouched)
#   ./badips-orchestrate.sh --static-realip
#       prod-homelab45's nginx logs the real visitor (files/real-ip-from-edge.conf).
#   ./badips-orchestrate.sh --verify [NN ...]
#       read-only: version, role, service, firewall table per node; the edge's
#       ban/feed counts; the shared list's active count.
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
CONFDIR=/usr/local/etc/badips.d

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
    case "$NEVER_BLOCK" in *23.116.91.64/29*) ;; *) die "$SITE: NEVER_BLOCK does not contain the house range 23.116.91.64/29" ;; esac
    case "$NEVER_BLOCK" in *198.51.100.45*) ;; *) die "$SITE: NEVER_BLOCK does not contain offsite 198.51.100.45" ;; esac
}
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

write_config(){ # NN ROLE
    local n="$1" role="$2"
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

node_status(){ # NN -> one line
    rsh "$1" 'v=$(dpkg-query -W -f="\${Version}" bad-ips 2>/dev/null || echo none)
              r=$(sudo /usr/local/sbin/bad_ips --test-config 2>/dev/null | sed -n "s/^role: *//p" | head -1)
              e=$(systemctl is-enabled bad_ips 2>/dev/null); a=$(systemctl is-active bad_ips 2>/dev/null)
              t=$(sudo nft list table inet badips >/dev/null 2>&1 && echo yes || echo no)
              echo "version=$v role=${r:-?} enabled=$e active=$a table=$t"' 2>/dev/null || echo unreachable
}

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
    local deb="$1" n; n="$(nn "$PG_NODE")"
    load_site
    [ -f "$deb" ] || die "no such package: $deb"
    case " $EDGES $REPORTERS $DB_NODES $PGB_NODES " in *" $n "*) die "prod-homelab$n is not a spare" ;; esac
    up "$n" || die "prod-homelab$n does not answer"
    say "proving ground on prod-homelab$n: block role, dropping ONLY on interface badipstest0 (which does not exist)"
    rsh "$n" "ip link show badipstest0 >/dev/null 2>&1" && die "an interface badipstest0 exists on prod-homelab$n"

    { printf '%s\n# PROVING GROUND: block role on a spare node, dropping ONLY on a made-up interface\n' "$HDR"
      printf '# no packet can arrive on, so this node is unaffected. Removed by the same run.\n[global]\n'
      printf 'role = block\ndry_run = 0\nblock_interfaces = badipstest0\nreconcile_interval = 30\n\n'
      printf '[rule:proving-ground]\nsource  = /var/lib/bad_ips/proving-ground.log\nformat  = nginx\n'
      printf 'match   = ^(?<ip>[0-9A-Fa-f.:]+) \\S+ \\S+ \\[[^\\]]+\\] "GET /\\.env\ncount   = 3\nwindow  = 600\nban     = 900\nservice = test\n'
    } | put "$n" "$CONFDIR/94-role.conf" || die "could not write the config"
    conf_fleet | put "$n" "$CONFDIR/95-fleet.conf"
    rsh "$n" "sudo rm -f $CONFDIR/96-fleet-db.conf"

    install_pkg "$n" "$deb" && ok "installed $(basename "$deb")" || { bad "install (see /tmp/badips-install.log on the node)"; return; }

    # A remote helper: wait up to $1 s for the shell test $2; print seconds or "timeout".
    local WAITFN='w(){ local t=0; while [ $t -lt $1 ]; do eval "$2" && { echo $t; return 0; }; sleep 1; t=$((t+1)); done; echo timeout; return 1; }
                  cnt(){ sudo nft -j list set inet badips "$1" 2>/dev/null | jq "[.nftables[] | select(.set) | .set.elem // [] | length] | add // 0"; }'

    local out
    out="$(rsh "$n" "$WAITFN"'
        echo "table_after=$(w 30 "sudo nft list table inet badips >/dev/null 2>&1")"
        echo "never4=$(cnt never_block)"; echo "never6=$(cnt never_block_v6)"
        echo "iface_rule=$(sudo nft list chain inet badips preroute_block | grep -c "iifname != \"badipstest0\"")"
        echo "dns_rule=$(sudo nft list chain inet badips preroute_block | grep -c "th dport 53 accept")"
        echo "feed_after=$(w 90 "[ \$(cnt feedv4) -gt 1000 ]")"; echo "feed4=$(cnt feedv4)"; echo "feed6=$(cnt feedv6)"
        TS=$(date -u +%d/%b/%Y:%H:%M:%S\ +0000)
        for i in 1 2 3; do echo "203.0.113.250 - - [$TS] \"GET /.env HTTP/1.1\" 404 162 \"-\" \"proving-ground\"" | sudo tee -a /var/lib/bad_ips/proving-ground.log >/dev/null; done
        echo "ban_after=$(w 15 "sudo nft list set inet badips badipv4 | grep -q 203.0.113.250")"
        sudo systemctl reload nftables
        echo "never4_after_reload=$(cnt never_block)"
        echo "ban_back_after_reload=$(w 45 "sudo nft list set inet badips badipv4 | grep -q 203.0.113.250")"
        echo "feed_back_after_reload=$(w 45 "[ \$(cnt feedv4) -gt 1000 ]")"
        sudo nft delete table inet badips
        echo "rebuilt_after_delete=$(w 45 "sudo nft list set inet badips badipv4 2>/dev/null | grep -q 203.0.113.250")"
        echo "never4_after_rebuild=$(cnt never_block)"
        echo "persist_file=$(test -f /etc/nftables.d/99-badips.nft && echo yes || echo no)"
        echo "persist_check=$(sudo nft -c -f /etc/nftables.d/99-badips.nft >/dev/null 2>&1 && echo ok || echo FAIL)"
        echo "base_filter=$(sudo nft list table inet filter >/dev/null 2>&1 && echo present || echo MISSING)"
        echo "errors=$(sudo grep -cE "\|(ERROR|FATAL)\|" /var/log/bad_ips/bad_ips.log 2>/dev/null)"
    ' 2>&1)"
    printf '%s\n' "$out" | sed 's/^/    /'
    v(){ printf '%s\n' "$out" | sed -n "s/^$1=//p" | head -1; }
    [ "$(v table_after)" != timeout ]          && ok "table built ($(v table_after) s after install)"        || bad "table never appeared"
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
    [ "$(v errors)" = 0 ]                       && ok "no errors in the daemon's log"                          || warn "$(v errors) error lines in /var/log/bad_ips/bad_ips.log"

    say "putting prod-homelab$n back to role off"
    conf_role off | put "$n" "$CONFDIR/94-role.conf"
    rsh "$n" "sudo rm -f /var/lib/bad_ips/proving-ground.log; sudo dpkg-reconfigure -f noninteractive bad-ips >/dev/null 2>&1"
    local st; st="$(node_status "$n")"
    case "$st" in *"role=off"*"enabled=disabled"*"active=inactive"*"table=no"*) ok "back to off: $st" ;; *) bad "after switching off: $st" ;; esac
    rsh "$n" "test -f /etc/nftables.d/99-badips.nft" && bad "persistent file still present" || ok "persistent file removed"
}

# ============================================================================
# --install / --role / --verify / --static-realip
# ============================================================================
all_nodes(){ local i; for i in $(seq "$FIRST" "$LAST"); do nn "$i"; done; }

do_install(){
    local deb="$1"; shift
    load_site; load_secret
    local nodes=("$@"); [ ${#nodes[@]} -eq 0 ] && mapfile -t nodes < <(all_nodes)
    say "installing bad-ips on ${#nodes[@]} node(s), $PAR at a time"
    local tmp; tmp="$(mktemp -d)"
    one(){
        local n; n="$(nn "$1")"; local role; role="$(role_for "$n")"
        if ! up "$n"; then echo "$n|$role|unreachable" > "$tmp/$n"; return; fi
        if write_config "$n" "$role" && install_pkg "$n" "$deb"; then
            echo "$n|$role|$(node_status "$n")" > "$tmp/$n"
        else
            echo "$n|$role|FAILED (see /tmp/badips-install.log on the node)" > "$tmp/$n"
        fi
    }
    local i=0 n
    for n in "${nodes[@]}"; do
        one "$n" &
        i=$((i + 1)); [ $((i % PAR)) -eq 0 ] && wait
    done
    wait
    local line role st
    for n in "${nodes[@]}"; do
        n="$(nn "$n")"; line="$(cat "$tmp/$n" 2>/dev/null || echo "$n|?|no result")"
        IFS='|' read -r _ role st <<<"$line"
        case "$st" in
            unreachable) case " $EDGES " in *" $n "*) warn "prod-homelab$n: powered off (parked edge) -- done in the rotation pass" ;; *) bad "prod-homelab$n: unreachable" ;; esac ;;
            FAILED*)     bad "prod-homelab$n ($role): $st" ;;
            *)           ok  "prod-homelab$n ($role): $st" ;;
        esac
    done
    rm -rf "$tmp"
}

do_role(){
    local n role; n="$(nn "$1")"; role="$2"
    case "$role" in block|watch|report|off) ;; *) die "role must be block, watch, report or off" ;; esac
    load_site; [ "$role" = off ] || load_secret
    say "prod-homelab$n -> $role"
    write_config "$n" "$role" || die "could not write the config"
    rsh "$n" "sudo dpkg-reconfigure -f noninteractive bad-ips" >/dev/null 2>&1 || bad "dpkg-reconfigure"
    ok "$(node_status "$n")"
}

do_verify(){
    local nodes=("$@"); [ ${#nodes[@]} -eq 0 ] && mapfile -t nodes < <(all_nodes)
    say "bad-ips on ${#nodes[@]} node(s)"
    local n
    for n in "${nodes[@]}"; do
        n="$(nn "$n")"
        if ! up "$n"; then case " $EDGES " in *" $n "*) warn "prod-homelab$n: powered off (parked edge)" ;; *) bad "prod-homelab$n: unreachable" ;; esac; continue; fi
        local st want; st="$(node_status "$n")"; want="$(role_for "$n")"
        printf '  prod-homelab%s  %s\n' "$n" "$st"
        case "$st" in
            *version=none*) bad "prod-homelab$n: not installed" ;;
            *"role=off"*)   [ "$want" = off ] || warn "prod-homelab$n: off, expected $want"
                            case "$st" in *"enabled=disabled"*"table=no"*) ;; *) bad "prod-homelab$n: role off but service or table present" ;; esac ;;
        esac
        case " $EDGES " in *" $n "*)
            rsh "$n" 'c(){ sudo nft -j list set inet badips "$1" 2>/dev/null | jq "[.nftables[] | select(.set) | .set.elem // [] | length] | add // 0"; }
                      echo "    blocking: $(c badipv4) addresses, $(c feedv4) + $(c feedv6) feed ranges; never-block $(c never_block) + $(c never_block_v6)"
                      sudo nft list chain inet badips preroute_block 2>/dev/null | grep -E "counter packets [1-9]" | sed "s/^\s*/    drops: /"' ;;
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
    --proving-ground) [ -n "$DEB" ] || die "--proving-ground needs --deb FILE"; do_proving_ground "$DEB" ;;
    --install)        do_install "$DEB" "${args[@]}" ;;
    --role)           [ ${#args[@]} -eq 2 ] || die "usage: --role NN block|watch|report|off"; do_role "${args[0]}" "${args[1]}" ;;
    --verify)         do_verify "${args[@]}" ;;
    --static-realip)  do_static_realip ;;
    --print-config)   [ ${#args[@]} -eq 1 ] || die "usage: --print-config NN"
                      load_site; BADIPS_DB_PASSWORD='********'
                      r="$(role_for "$(nn "${args[0]}")")"
                      echo "### prod-homelab$(nn "${args[0]}"): role $r"
                      echo "### $CONFDIR/94-role.conf";  conf_role "$r"
                      echo "### $CONFDIR/95-fleet.conf"; conf_fleet
                      [ "$r" = off ] && echo "### (no 96-fleet-db.conf: role off does not use the database)" \
                                     || { echo "### $CONFDIR/96-fleet-db.conf"; conf_db; }
                      exit 0 ;;
    *) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
echo
[ "$FAILS" -eq 0 ] && printf '%sdone, no failures%s\n' "$G" "$O" || printf '%s%d failure(s)%s\n' "$R" "$FAILS" "$O"
[ "$FAILS" -eq 0 ]
