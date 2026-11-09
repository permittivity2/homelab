#!/bin/bash
# ============================================================================
# Service exporters for the fleet's Prometheus -- RUN ON THIS HOST (desktop).
#
# metrics-orchestrate.sh stands up Prometheus + Grafana and node-exporter. The
# per-service exporters were never part of it, so on the greenfield fleet the
# Database, Mail Flow and Proxy dashboards sat empty (post-cutover #43): the
# scrape jobs existed, their target files were just `[]`, and nothing complains
# about an empty target file.
#
#   metrics-exporters-orchestrate.sh --install   # install them, in a safe order
#   metrics-exporters-orchestrate.sh --verify    # every scrape job has live targets?
#
# Order matters:
#   * postgres-exporter: LEADER first (it creates the passwordless `prometheus`
#     role, which then replicates), then the replicas. A replica cannot write.
#   * pgbouncer-exporter: nodes WITHOUT the VIP first. Its postinst makes
#     homelab-pgbouncer regenerate its config and reload (never restart).
#   * dovecot-metrics: backup IMAP nodes before the active one (it reloads dovecot).
#
# Node numbers below are this fleet's layout (see post-cutover/README.md).
# --verify exits 1 on a job with no target, or with any target down (all three
# edges are live since item 44, so none is exempt).
# ============================================================================
set -uo pipefail

ip_of(){ printf '10.20.2.%d' "$((144 + 10#$1))"; }
say(){ printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
METRICS_NODE="${METRICS_NODE:-69}"
VIP_PGB="10.50.2.131"

install_on(){   # install_on <pkg> <node...>
  local pkg="$1" n out rc; shift
  for n in "$@"; do
    echo "-- $pkg on $n"
    # Judge by apt's exit code, not by whether anything matched a grep: a
    # package that is already current prints nothing grep-worthy, and the
    # old form reported every such no-op as "failed" (seen 2026-11-09).
    out="$(ssh -o ConnectTimeout=8 "$(ip_of "$n")" "sudo apt-get update -qq >/dev/null 2>&1
      sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends $pkg 2>&1")"; rc=$?
    if [ "$rc" -ne 0 ]; then
      echo "   !! $n failed (exit $rc):"; printf '%s\n' "$out" | tail -6 | sed 's/^/      /'
      continue
    fi
    printf '%s\n' "$out" | grep -iE 'error|warning|configured|already the newest' | sed 's/^/   /'
    printf '%s\n' "$out" | grep -qiE 'configured|already the newest' || echo "   ok (no output)"
  done
}

leader_first_db(){   # prints the DB nodes with the leader first
  local leader="" rest=""
  for n in 06 07 08; do
    if [ "$(ssh "$(ip_of $n)" "sudo -u postgres psql -tAc 'select pg_is_in_recovery()'" 2>/dev/null | tr -d '[:space:]')" = "f" ]; then leader="$n"; else rest="$rest $n"; fi
  done
  echo "$leader$rest"
}

pgb_vip_last(){      # pgbouncer nodes, the one holding the VIP last
  local first="" last=""
  for n in 09 10 11; do
    if ssh "$(ip_of $n)" "ip -4 -o addr | grep -q ' $VIP_PGB/'" 2>/dev/null; then last="$n"; else first="$first $n"; fi
  done
  echo "$first $last"
}

do_install(){
  say "postgres-exporter (leader first)";  install_on homelab-postgres-exporter $(leader_first_db)
  say "pgbouncer-exporter (VIP holder last)"; install_on homelab-pgbouncer-exporter $(pgb_vip_last)
  say "dovecot-metrics (backups first)";   install_on homelab-dovecot-metrics 63 64 62
  say "postfix-exporter (mail relays)";    install_on homelab-postfix-exporter 39 40 41
  say "nginx-exporter (all three live edges + static 45)"
  install_on homelab-nginx-exporter 00 01 02 45
  echo "   NB: 45 runs no homelab-agent, so it is not discovered as a target until it is enrolled."
  say "blackbox-exporter (public HTTPS probes + cert expiry; runs on the monitoring host)"
  install_on homelab-blackbox-exporter "$METRICS_NODE"
  echo; echo "Targets appear within ~2 minutes (homelab-prometheus-pull timer). Then: $0 --verify"
}

do_verify(){
  local rc=0 m; m="$(ip_of "$METRICS_NODE")"
  say "scrape jobs on prod-homelabvm$METRICS_NODE"
  ssh "$m" 'curl -s localhost:9090/api/v1/targets' | perl -MJSON::PP -e '
    my $d = decode_json(join "", <STDIN>); my (%n, %up, @bad);
    for (@{ $d->{data}{activeTargets} }) {
      my ($j, $u) = ($_->{labels}{job}, $_->{scrapeUrl});
      $n{$j}++; $up{$j}++ if $_->{health} eq "up";
      # All three edges (10.50.2.144-146) are live since item 44, so none is exempt.
      push @bad, "$j $u" if $_->{health} ne "up";
    }
    my $rc = 0;
    for my $j (qw(node postgres pgbouncer postfix haproxy dnsdist pdns dovecot nginx blackbox-http)) {
      my ($t, $u) = ($n{$j} // 0, $up{$j} // 0);
      printf "  %-10s %d target(s), %d up%s\n", $j, $t, $u, $t ? "" : "   <-- NO TARGETS";
      $rc = 1 unless $t;
    }
    if (@bad) { print "  DOWN:\n", map("    $_\n", @bad); $rc = 1 }
    exit $rc;' || rc=1
  [ $rc = 0 ] && echo "OK: every scrape job has live targets." || echo "FINDINGS above."
  return $rc
}

case "${1:-}" in
  --install) do_install ;;
  --verify)  do_verify; exit $? ;;
  *) sed -n 2,24p "$0"; exit 2 ;;
esac
