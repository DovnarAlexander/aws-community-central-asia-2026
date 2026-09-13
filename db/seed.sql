-- Two million rows, loaded once into RDS and then snapshotted.
--
-- The size is the point. `SELECT count(*) ... LIKE '%needle%'` cannot use an
-- index and cannot be cheap, which is what turns a readiness probe into load.
-- Anything much smaller and the antipattern stops being visible; anything much
-- larger and seeding outgrows the time between rehearsals.
--
-- generate_series runs server-side, so this transfers almost nothing over the
-- network despite producing roughly 250 MB.

\set ON_ERROR_STOP on

-- Without this the stage goes blind exactly when it matters.
--
-- When incident 2 exhausts max_connections, every new connection is refused --
-- including the one the panel showing the connection count wants to open. RDS
-- does keep slots back, but for its own internal rds_reserved role, and the
-- master user is a member of rds_superuser rather than a real superuser, so
-- superuser_reserved_connections does not apply to it either.
--
-- PostgreSQL 16's pg_use_reserved_connections is the mechanism that does apply:
-- members get the slots held by reserved_connections. The observer needs its
-- own reserved capacity, or it cannot observe the thing it is there to watch.
GRANT pg_use_reserved_connections TO postgres;

CREATE TABLE IF NOT EXISTS items (
    id      bigserial PRIMARY KEY,
    payload text NOT NULL
);

DO $$
DECLARE
    existing bigint;
BEGIN
    SELECT count(*) INTO existing FROM items;

    IF existing >= 2000000 THEN
        RAISE NOTICE 'items already holds % rows, skipping', existing;
        RETURN;
    END IF;

    -- Re-running a partially loaded seed would leave a table that is the wrong
    -- size, and every timing in incident 2 is calibrated against two million rows.
    TRUNCATE items RESTART IDENTITY;

    INSERT INTO items (payload)
    SELECT md5(g::text) || md5((g::bigint * 7919)::text) || md5((g::bigint * 104729)::text)
    FROM generate_series(1, 2000000) AS g;
END $$;

VACUUM (ANALYZE) items;

SELECT count(*) AS rows_seeded FROM items;
