#!/usr/bin/env python3
"""Generate grafana/dashboards/resolver.json (homelab-grafana), following the
structure of dns-overview.json (schemaVersion 39, datasource uid homelab-prometheus)."""
import json, sys

DS = {"type": "prometheus", "uid": "homelab-prometheus"}
R = 'job="pdns-recursor"'      # recursor metrics
N = 'job="node", tier="legacy"'  # the resolver host's node_exporter (static target)

def tgt(expr, legend="", ref="A"):
    return {"refId": ref, "datasource": DS, "expr": expr, "legendFormat": legend}

def stat(title, expr, x, w, unit, steps, h=4, y=0, graph="area"):
    return {
        "type": "stat", "title": title, "datasource": DS,
        "gridPos": {"h": h, "w": w, "x": x, "y": y},
        "fieldConfig": {"defaults": {"unit": unit, "thresholds": {"mode": "absolute", "steps": steps}}, "overrides": []},
        "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
                    "colorMode": "value", "graphMode": graph, "textMode": "value"},
        "targets": [tgt(expr)],
    }

def ts(title, targets, x, y, w=12, h=8, unit="reqps", stacking="none", fill=8, extra=None):
    defaults = {"unit": unit, "custom": {"drawStyle": "line", "fillOpacity": fill, "lineWidth": 1,
                                         "showPoints": "never", "stacking": {"mode": stacking}}}
    if extra:
        defaults.update(extra)
    return {
        "type": "timeseries", "title": title, "datasource": DS,
        "gridPos": {"h": h, "w": w, "x": x, "y": y},
        "fieldConfig": {"defaults": defaults, "overrides": []},
        "options": {"legend": {"displayMode": "list", "placement": "bottom", "showLegend": True},
                    "tooltip": {"mode": "multi", "sort": "desc"}},
        "targets": [tgt(e, l, chr(65 + i)) for i, (e, l) in enumerate(targets)],
    }

def bargauge(title, expr, legend, x, y, w=12, h=10, unit="short"):
    return {
        "type": "bargauge", "title": title, "datasource": DS,
        "gridPos": {"h": h, "w": w, "x": x, "y": y},
        "fieldConfig": {"defaults": {"unit": unit, "min": 0, "color": {"mode": "continuous-BlPu"},
                                     "thresholds": {"mode": "absolute", "steps": [{"color": "blue", "value": None}]}},
                        "overrides": []},
        "options": {"orientation": "horizontal", "displayMode": "gradient", "showUnfilled": True,
                    "valueMode": "color", "namePlacement": "left", "sizing": "auto",
                    "minVizHeight": 16, "maxVizHeight": 32,
                    "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False}},
        "targets": [tgt(expr, legend)],
    }

HIDE = {"Time": True, "__name__": True, "instance": True, "job": True, "host": True, "tier": True, "fleet": True}

def table(title, expr, x, y, w=8, h=10, unit="percentunit", rename=None):
    t = tgt(expr); t.update({"format": "table", "instant": True})
    return {
        "type": "table", "title": title, "datasource": DS,
        "gridPos": {"h": h, "w": w, "x": x, "y": y},
        "fieldConfig": {"defaults": {"unit": unit, "custom": {"align": "auto", "cellOptions": {"type": "auto"}}},
                        "overrides": [{"matcher": {"id": "byName", "options": "share"},
                                       "properties": [{"id": "custom.cellOptions", "value": {"type": "gauge", "mode": "gradient"}},
                                                      {"id": "min", "value": 0}, {"id": "max", "value": 1}]}]},
        "options": {"showHeader": True, "cellHeight": "sm", "sortBy": [{"displayName": "share", "desc": True}]},
        "targets": [t],
        "transformations": [{"id": "organize", "options": {"excludeByName": HIDE,
                                                            "renameByName": dict({"Value": "share"}, **(rename or {}))}}],
    }

green_up = [{"color": "red", "value": None}, {"color": "green", "value": 1}]
rate_bad = [{"color": "green", "value": None}, {"color": "yellow", "value": 0.5}, {"color": "red", "value": 2}]
pct_good = [{"color": "red", "value": None}, {"color": "yellow", "value": 40}, {"color": "green", "value": 70}]

panels = [
    # --- row 0: stats --------------------------------------------------------
    stat("Queries /s", f"sum(rate(pdns_recursor_questions{{{R}}}[5m]))", 0, 4, "reqps",
         [{"color": "blue", "value": None}]),
    stat("Packet-cache hit", f"100 * sum(rate(pdns_recursor_packetcache_hits{{{R}}}[5m])) / clamp_min(sum(rate(pdns_recursor_packetcache_hits{{{R}}}[5m])) + sum(rate(pdns_recursor_packetcache_misses{{{R}}}[5m])), 0.01)",
         4, 4, "percent", pct_good),
    stat("Record-cache hit", f"100 * sum(rate(pdns_recursor_cache_hits{{{R}}}[5m])) / clamp_min(sum(rate(pdns_recursor_cache_hits{{{R}}}[5m])) + sum(rate(pdns_recursor_cache_misses{{{R}}}[5m])), 0.01)",
         8, 4, "percent", [{"color": "red", "value": None}, {"color": "yellow", "value": 15}, {"color": "green", "value": 30}]),
    stat("SERVFAIL /s", f"sum(rate(pdns_recursor_servfail_answers{{{R}}}[5m]))", 12, 4, "reqps", rate_bad),
    stat("NXDOMAIN /s", f"sum(rate(pdns_recursor_nxdomain_answers{{{R}}}[5m]))", 16, 4, "reqps",
         [{"color": "blue", "value": None}]),
    stat("Resolver uptime", f"max(pdns_recursor_uptime{{{R}}})", 20, 4, "dtdurations",
         [{"color": "red", "value": None}, {"color": "yellow", "value": 300}, {"color": "green", "value": 3600}], graph="none"),

    # --- row 1 -----------------------------------------------------------------
    ts("Answers by rcode /s", [
        (f"sum(rate(pdns_recursor_noerror_answers{{{R}}}[5m]))", "NOERROR"),
        (f"sum(rate(pdns_recursor_nxdomain_answers{{{R}}}[5m]))", "NXDOMAIN"),
        (f"sum(rate(pdns_recursor_servfail_answers{{{R}}}[5m]))", "SERVFAIL"),
    ], 0, 4, stacking="normal"),
    ts("Cache hits vs misses /s", [
        (f"sum(rate(pdns_recursor_packetcache_hits{{{R}}}[5m]))", "packet-cache hits"),
        (f"sum(rate(pdns_recursor_packetcache_misses{{{R}}}[5m]))", "packet-cache misses"),
        (f"sum(rate(pdns_recursor_cache_hits{{{R}}}[5m]))", "record-cache hits"),
        (f"sum(rate(pdns_recursor_cache_misses{{{R}}}[5m]))", "record-cache misses"),
    ], 12, 4),

    # --- row 2 -----------------------------------------------------------------
    ts("Outgoing queries /s (to authoritative servers)", [
        (f"sum(rate(pdns_recursor_all_outqueries{{{R}}}[5m]))", "all"),
        (f"sum(rate(pdns_recursor_tcp_outqueries{{{R}}}[5m]))", "tcp"),
        (f"sum(rate(pdns_recursor_outgoing_timeouts{{{R}}}[5m]))", "timeouts"),
        (f"sum(rate(pdns_recursor_throttled_out{{{R}}}[5m]))", "throttled"),
    ], 0, 12),
    ts("Answer latency share (client answers by bucket)", [
        (f"sum(rate(pdns_recursor_answers0_1{{{R}}}[5m]))", "< 1 ms"),
        (f"sum(rate(pdns_recursor_answers1_10{{{R}}}[5m]))", "1-10 ms"),
        (f"sum(rate(pdns_recursor_answers10_100{{{R}}}[5m]))", "10-100 ms"),
        (f"sum(rate(pdns_recursor_answers100_1000{{{R}}}[5m]))", "100-1000 ms"),
        (f"sum(rate(pdns_recursor_answers_slow{{{R}}}[5m]))", "> 1 s"),
    ], 12, 12, unit="reqps", stacking="percent", fill=40),

    # --- row 3 -----------------------------------------------------------------
    ts("Cache entries", [
        (f"sum(pdns_recursor_cache_entries{{{R}}})", "record cache"),
        (f"sum(pdns_recursor_packetcache_entries{{{R}}})", "packet cache"),
        (f"sum(pdns_recursor_negcache_entries{{{R}}})", "negative cache"),
        (f"max(pdns_recursor_max_cache_entries{{{R}}})", "max-cache-entries"),
    ], 0, 20, unit="short", fill=0),
    ts("Concurrent queries & TCP clients", [
        (f"sum(pdns_recursor_concurrent_queries{{{R}}})", "concurrent queries"),
        (f"sum(pdns_recursor_tcp_clients{{{R}}})", "tcp clients"),
        (f"sum(rate(pdns_recursor_over_capacity_drops{{{R}}}[5m]))", "over-capacity drops /s"),
    ], 12, 20, unit="short", fill=0),

    # --- row 4: the host (512 MB) ----------------------------------------------
    ts("Host memory used % (node_exporter)", [
        (f"100 * (1 - node_memory_MemAvailable_bytes{{{N}}} / node_memory_MemTotal_bytes{{{N}}})", "{{host}} used %"),
    ], 0, 28, unit="percent", fill=10, extra={"min": 0, "max": 100}),
    ts("Host CPU busy % and load", [
        (f"100 - (avg by(host)(rate(node_cpu_seconds_total{{{N}, mode=\"idle\"}}[5m])) * 100)", "{{host}} cpu busy %"),
        # both sides reduced to {host} so the division matches (a bare node_load1 carries instance/job/tier too)
        (f"avg by(host)(node_load1{{{N}}}) * 100 / count by(host)(node_cpu_seconds_total{{{N}, mode=\"idle\"}})", "{{host}} load1 (% of cores)"),
    ], 12, 28, unit="percent", fill=0),
    ts("Recursor process memory", [
        (f"sum by(host)(pdns_recursor_real_memory_usage{{{R}}})", "{{host}} recursor RSS"),
    ], 0, 36, unit="bytes", fill=10),
    ts("Host root disk used %", [
        (f"100 * (1 - node_filesystem_avail_bytes{{{N}, mountpoint=\"/\"}} / node_filesystem_size_bytes{{{N}, mountpoint=\"/\"}})", "{{host}} /"),
    ], 12, 36, unit="percent", fill=10, extra={"min": 0, "max": 100}),

    # --- rows 5-7: who asks what. From recursor-top-metrics (rec_control
    # top-*, textfile collector on the host): shares of the recursor's last
    # 10,000 queries, refreshed every 60 s. share * ring entries = count. ----
    stat("Share from outside 10.0.0.0/8 (should be 0)",
         f"sum(pdns_recursor_top_remote_share{{{N}, client!~\"^10\\\\..*\"}}) or vector(0)", 0, 6, "percentunit",
         [{"color": "green", "value": None}, {"color": "red", "value": 0.0001}], y=44, graph="none"),
    stat("Clients in the top 20", f"count(pdns_recursor_top_remote_share{{{N}}})", 6, 6, "short",
         [{"color": "blue", "value": None}], y=44, graph="none"),
    stat("Queries in the client ring", f"max(pdns_recursor_top_ringbuffer_entries{{{N}, ranking=\"remotes\"}})", 12, 6, "short",
         [{"color": "blue", "value": None}], y=44, graph="none"),
    stat("Rankings age", f"time() - max(pdns_recursor_top_metrics_timestamp_seconds{{{N}}})", 18, 6, "s",
         [{"color": "green", "value": None}, {"color": "yellow", "value": 180}, {"color": "red", "value": 600}], y=44, graph="none"),

    bargauge("Queries by client (approx. count in the last ring of queries)",
             f"sort_desc(pdns_recursor_top_remote_share{{{N}}} * on(instance) group_left pdns_recursor_top_ringbuffer_entries{{{N}, ranking=\"remotes\"}})",
             "{{client}}", 0, 48),
    ts("Client share over time", [
        (f"pdns_recursor_top_remote_share{{{N}}}", "{{client}}"),
    ], 12, 48, h=10, unit="percentunit", stacking="normal", fill=30),

    table("Top names (cache-missing queries)", f"sort_desc(pdns_recursor_top_query_share{{{N}}})", 0, 58, w=8),
    table("SERVFAIL by client", f"sort_desc(pdns_recursor_top_servfail_remote_share{{{N}}})", 8, 58, w=8),
    table("SERVFAIL by name", f"sort_desc(pdns_recursor_top_servfail_query_share{{{N}}})", 16, 58, w=8),
    table("Authoritative servers timing out", f"sort_desc(pdns_recursor_top_timeout_server_share{{{N}}})", 0, 68, w=8, h=8),
]

dash = {
    "uid": "homelab-resolver",
    "title": "Resolver (pdns-recursor on ns03)",
    "description": "ns03 is the only resolver for every network and not a fleet member: scraped as a static target (post-cutover #66). Rates are 5-minute; 'legacy' host panels read node_exporter on the same host.",
    "tags": ["homelab", "dns", "resolver"],
    "timezone": "browser",
    "schemaVersion": 39,
    "version": 1,
    "refresh": "30s",
    "time": {"from": "now-6h", "to": "now"},
    "templating": {"list": []},
    "annotations": {"list": []},
    "panels": panels,
}

out = sys.argv[1]
with open(out, "w") as f:
    json.dump(dash, f, indent=2)
    f.write("\n")
print(out, len(panels), "panels")
