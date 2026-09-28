-- Chunked / resumable uploads.
--
-- The whole-file POST /api/v1/files path still exists (small files, and
-- any client that doesn't care to chunk), but a 4GB upload sent as one
-- request is fragile: a single dropped connection wastes the entire
-- transfer, and every hop (webproxy, the homelab-api gateway, this app)
-- has to be willing to hold/stream one enormous body. This protocol
-- lets a client cut the file into ordered, offset-addressed chunks and
-- send them one request at a time, resuming from wherever the server
-- last had complete bytes if the connection drops:
--
--   POST   /uploads            -> {upload_id, offset:0, chunk_size}
--   GET    /uploads/<id>       -> {offset, total_size, state, file_id?}
--   PATCH  /uploads/<id>       (Upload-Offset header + raw chunk body)
--                              -> {offset, done, file_id?}
--   DELETE /uploads/<id>       -> abort, drop the partial
--
-- The partial bytes accumulate in ONE file per session at
-- storage_path/.partials/<id> -- on the storage filesystem, deliberately
-- NOT the RAM-backed tmpfs /tmp (a big upload must spill to real disk,
-- never OOM the box), and same-filesystem so the finalizing rename into
-- storage_path/<file uuid> is a cheap metadata move, not a byte copy.
-- The ON-DISK size of that partial is the authoritative resume offset;
-- received_bytes here mirrors it for cheap GET/HEAD-style status without
-- touching disk, and drives the stale-session sweeper.
--
-- Why the client-facing response never uses HTTP response *headers* for
-- the offset (the tus.io way): the homelab-api gateway relays only the
-- backend's response BODY + content-type, not arbitrary response
-- headers (see Homelab::Common::Proxy::forward) -- so offset/state must
-- travel in the JSON body to survive the gateway hop. Request headers
-- (Upload-Offset) forward through fine.
CREATE TABLE IF NOT EXISTS drive.upload_sessions (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_email     TEXT NOT NULL,
    filename       TEXT NOT NULL,
    total_size     BIGINT NOT NULL CHECK (total_size >= 0),
    received_bytes BIGINT NOT NULL DEFAULT 0,
    folder_id      BIGINT REFERENCES drive.folders(id) ON DELETE CASCADE,   -- NULL == root
    state          TEXT NOT NULL DEFAULT 'open'
                       CHECK (state IN ('open', 'completed', 'aborted')),
    result_file_id BIGINT,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_upload_sessions_user  ON drive.upload_sessions(user_email);
-- The sweeper only ever scans still-open, idle sessions.
CREATE INDEX IF NOT EXISTS idx_upload_sessions_stale ON drive.upload_sessions(updated_at) WHERE state = 'open';
