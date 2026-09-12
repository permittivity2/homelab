-- Pre-creates 24 months of audit.entries partitions (this month plus
-- the next 23), instead of the recurring runtime timer creating them
-- on the fly as originally designed. That original design was wrong:
-- CREATE TABLE ... PARTITION OF is DDL, and homelab-audit's own
-- runtime role deliberately has no DDL privileges at all (the split-
-- role design's whole point -- see homelab-bootstrap-app-role's own
-- comment: "Used only transiently by postinst/upgrade... never held
-- by the running daemon"). Caught for real: "permission denied for
-- schema audit" from the live running service, not by inspection.
--
-- This migration runs as the MIGRATE role (which does hold DDL), so
-- it's the correct place for this. 24 months is deliberately generous
-- headroom, not a promise of automatic forever-coverage -- extending
-- further into the future, when needed, is a new migration file, the
-- same bounded, occasional operational task this project already
-- accepts for retention/cleanup (see 001-audit.sql's own comment).
DO $$
DECLARE
    i int;
    part_start date;
    part_end   date;
    part_name  text;
BEGIN
    FOR i IN 0..23 LOOP
        part_start := date_trunc('month', now()) + (i || ' months')::interval;
        part_end   := part_start + interval '1 month';
        part_name  := 'entries_' || to_char(part_start, 'YYYY_MM');
        IF NOT EXISTS (SELECT 1 FROM pg_class WHERE relname = part_name) THEN
            EXECUTE format(
                'CREATE TABLE audit.%I PARTITION OF audit.entries FOR VALUES FROM (%L) TO (%L)',
                part_name, part_start, part_end
            );
        END IF;
    END LOOP;
END $$;
