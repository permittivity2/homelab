-- Which worker node holds a finished job's output (post-cutover item 51).
--
-- A job's output is written to the local disk of whichever node ran it
-- (storage_path/<output_uuid>), but with three workers behind the registry a
-- download, or the expiry sweep, can land on any of them. Downloads failed
-- ("output file is missing") whenever they reached another node, which made
-- Drive's "download as zip" fail every time it did; and the sweep on another
-- node deleted the row and left the file on disk forever.
--
-- output_node is the owning node's service address (host:port, its registry
-- entry), set when the job completes. A download reaching another node is
-- relayed from the owner, and only the owner deletes its file. NULL is a job
-- from before this column, or a node with no registry entry (a single dev
-- host), where "local" is the only place it can be.

ALTER TABLE worker.jobs ADD COLUMN IF NOT EXISTS output_node TEXT;
