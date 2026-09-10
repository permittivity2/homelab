-- Debounces "systemctl restart pdns" across a burst of new-zone/new-name
-- writes (e.g. one "add domain" call writing a zone + MX + SPF in quick
-- succession should trigger exactly ONE restart, not several) -- see
-- README.md's "PowerDNS caches its zone list at process start" section
-- and Homelab::DomainAdmin::App's recurring debounce timer. Single-row
-- table (id is always TRUE) so a repeated write is just an upsert, not
-- a growing queue.
CREATE TABLE IF NOT EXISTS domainadmin.pending_restart (
    id        BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK (id),
    reason    TEXT,
    marked_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
