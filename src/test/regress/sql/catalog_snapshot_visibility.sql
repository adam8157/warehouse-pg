-- Test: reader gang must see tables created in the same transaction.
--
-- Root cause: GetCatalogSnapshot() hardcodes DTX_CONTEXT_LOCAL_ONLY, so
-- reader QEs build their catalog snapshot from local ProcArray instead of
-- copying from the writer gang.  Combined with currentCommandId stuck at 0
-- (SetSharedTransactionId_reader not yet called), the writer's pg_class
-- rows (cmin > 0) are invisible to the reader → "could not open relation
-- with OID".
--
-- The bug is a race: it only fires when a NEW reader gang process is
-- allocated that has never called SetSharedTransactionId_reader.  We
-- increase the odds by:
--   1. Running multiple commands before the query (pushing cmin > 0)
--   2. Using a multi-slice join that forces redistribution
--   3. Looping to hit the gang-allocation window

-- Simple case: CREATE + immediate multi-slice query in same transaction
BEGIN;
CREATE TABLE catalog_snap_t1 (a int, b int) DISTRIBUTED BY (a);
CREATE TABLE catalog_snap_t2 (x int, y int) DISTRIBUTED BY (y);
INSERT INTO catalog_snap_t1 SELECT i, i FROM generate_series(1, 100) i;
INSERT INTO catalog_snap_t2 SELECT i, i FROM generate_series(1, 100) i;

-- Join on non-distribution keys forces Redistribute Motion on both sides,
-- creating multiple slices with reader gangs that must open both tables.
SELECT count(*) FROM catalog_snap_t1 t1 JOIN catalog_snap_t2 t2 ON t1.b = t2.x;
ABORT;

-- Heavier case: more commands to push cmin higher, then 3-way join for
-- more slices and higher chance of new gang allocation.
BEGIN;
CREATE TABLE catalog_snap_t3 (a int) DISTRIBUTED BY (a);
CREATE TABLE catalog_snap_t4 (b int) DISTRIBUTED BY (b);
CREATE TABLE catalog_snap_t5 (c int) DISTRIBUTED BY (c);
INSERT INTO catalog_snap_t3 SELECT generate_series(1, 200);
INSERT INTO catalog_snap_t4 SELECT generate_series(1, 200);
INSERT INTO catalog_snap_t5 SELECT generate_series(1, 200);

-- cmin of catalog_snap_t5 is at least 5 here.  A new reader gang with
-- currentCommandId=0 will fail the cmin < curcid visibility check.
SELECT count(*)
FROM catalog_snap_t3 t3
JOIN catalog_snap_t4 t4 ON t3.a = t4.b
JOIN catalog_snap_t5 t5 ON t4.b = t5.c;
ABORT;

-- Loop variant: repeat to increase reproduction probability.
-- Each iteration creates a fresh table inside a transaction and immediately
-- queries it with a redistributing join.
DO $$
BEGIN
  FOR i IN 1..20 LOOP
    BEGIN
      EXECUTE 'CREATE TABLE catalog_snap_loop (a int, b int) DISTRIBUTED BY (a)';
      EXECUTE 'INSERT INTO catalog_snap_loop SELECT g, g+1 FROM generate_series(1, 50) g';
      -- Self-join on non-distribution key forces redistribution
      PERFORM count(*) FROM catalog_snap_loop t1 JOIN catalog_snap_loop t2 ON t1.b = t2.a;
      EXECUTE 'DROP TABLE catalog_snap_loop';
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'iteration % failed: %', i, SQLERRM;
      EXECUTE 'DROP TABLE IF EXISTS catalog_snap_loop';
    END;
  END LOOP;
END $$;

-- ============================================================
-- Deterministic test using fault injection.
--
-- The fault "reader_set_xid_clear_curcid" fires at the end of
-- SetSharedTransactionId_reader(), AFTER readerFillLocalSnapshot
-- has set the correct curcid.  It resets currentCommandId to 0
-- and invalidates all caches, so subsequent catalog lookups
-- (RelationBuildDesc → ScanPgRelation → GetCatalogSnapshot) must
-- re-read pg_class with curcid=0.
--
-- Without fixes: GetCatalogSnapshot uses DTX_CONTEXT_LOCAL_ONLY,
-- so it doesn't call readerFillLocalSnapshot again → curcid stays
-- at 0 → MVCC check "cmin < curcid" fails → "could not open
-- relation with OID".
--
-- With fix 1 (curcid in StartTransaction): curcid was set before
-- GetTransactionSnapshot, but the fault fires AFTER that and
-- resets it, so fix 1 alone is NOT sufficient to pass this test.
--
-- With fix 2 (GetCatalogSnapshot using DistributedTransactionContext):
-- GetCatalogSnapshot → GetSnapshotData(QE_READER) →
-- readerFillLocalSnapshot → SetSharedTransactionId_reader re-sets
-- the correct curcid → MVCC passes → query succeeds.
-- ============================================================

BEGIN;
CREATE TABLE catalog_snap_fi_t1 (a int, b int) DISTRIBUTED BY (a);
CREATE TABLE catalog_snap_fi_t2 (x int, y int) DISTRIBUTED BY (y);
INSERT INTO catalog_snap_fi_t1 SELECT i, i FROM generate_series(1, 100) i;
INSERT INTO catalog_snap_fi_t2 SELECT i, i FROM generate_series(1, 100) i;

-- Activate fault AFTER inserts, so it only affects the SELECT.
SELECT gp_inject_fault('reader_set_xid_clear_curcid', 'skip',
                        dbid) FROM gp_segment_configuration
WHERE role = 'p' AND content >= 0;

SELECT count(*) FROM catalog_snap_fi_t1 t1 JOIN catalog_snap_fi_t2 t2 ON t1.b = t2.x;
ABORT;

-- Deactivate fault
SELECT gp_inject_fault('reader_set_xid_clear_curcid', 'reset',
                        dbid) FROM gp_segment_configuration
WHERE role = 'p' AND content >= 0;
