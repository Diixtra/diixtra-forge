# etcd Compaction and Defragmentation

## Why etcd Grows Over Time

etcd is a key-value store that uses **multi-version concurrency control (MVCC)**. Every
write creates a new *revision* rather than overwriting the old value. This means:

```
PUT /registry/pods/default/nginx  → revision 100 (value: v1 of the pod spec)
PUT /registry/pods/default/nginx  → revision 200 (value: v2 of the pod spec)
DELETE /registry/pods/default/nginx → revision 300 (tombstone marker)
```

All three revisions are kept until explicitly removed. In a Kubernetes cluster, every pod
scheduling decision, lease renewal, and status update creates new revisions. The database
grows continuously.

## Compaction — Removing Old Revisions

**Compaction** tells etcd to discard all revisions older than a specified revision number.
After compacting to revision 300, revisions 100 and 200 are marked as reclaimable — you
can no longer query the historical state of the key.

```bash
# Get current revision
REVISION=$(etcdctl endpoint status --write-out=json | jq '.[0].Status.header.revision')

# Compact everything up to the current revision
etcdctl compact $REVISION
```

Kubernetes runs auto-compaction by default (`--auto-compaction-retention=5m`), which
compacts revisions older than 5 minutes. But during crash-loop storms, compaction can
fall behind because etcd is too busy to run it.

**When to manually compact:** After a crash-loop recovery when the database has grown
significantly. Check with `endpoint status` — if "PERCENTAGE NOT IN USE" is >50%, manual
compaction helps.

## Defragmentation — Reclaiming Disk Space

Compaction marks old revisions as reclaimable, but **doesn't actually free disk space**.
etcd uses bbolt (a B+ tree database) which allocates pages but never returns them to the
OS. After compaction, the database file stays the same size — it just has holes in it.

**Defragmentation** reorganises the database file, removing the holes and shrinking it:

```bash
etcdctl defrag --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key
```

### Important Caveats

1. **Defrag blocks all reads and writes** while it runs. On a single-node cluster (like
   ours), this means the entire Kubernetes API is frozen during defrag. On a multi-node
   cluster, defrag one member at a time.

2. **Defrag temporarily doubles disk usage** — it creates a new database file, copies
   data, then replaces the old one. Ensure `/var/lib/etcd` has enough free space.

3. **Only defrag after compaction** — defrag without compaction achieves nothing because
   there are no reclaimable pages.

## Reading the Numbers

From `etcdctl endpoint status`:

```
| DB SIZE | IN USE | PERCENTAGE NOT IN USE |
|   87 MB |  36 MB |                   59% |
```

- **DB SIZE (87 MB):** Total bbolt file size on disk
- **IN USE (36 MB):** Data that's actually referenced
- **NOT IN USE (59%):** Space reclaimable by defragmentation

This cluster had 59% fragmentation after the crash-loop storm — normal after heavy
compaction. Defragmentation would shrink the DB from 87MB to ~36MB.

## The WAL (Write-Ahead Log)

Separate from the database, the WAL at `/var/lib/etcd/member/wal/` records every proposed
change before it's applied. etcd replays the WAL on startup to recover state.

- WAL files are pre-allocated in 64MB segments
- Our WAL was 422MB (about 7 segments) — normal for a cluster that's been running
- Large WAL + slow disk = very slow startup (etcd must replay every entry sequentially)
- WAL is automatically truncated after snapshots — the `--snapshot-count` flag controls
  how many entries between snapshots (default changed in etcd 3.6)

## When to Worry

| Metric | Healthy | Warning | Critical |
|--------|---------|---------|----------|
| DB SIZE | <100MB | 100-500MB | >500MB |
| NOT IN USE | <30% | 30-50% | >50% |
| fdatasync p99 | <10ms | 10-100ms | >100ms |
| WAL size | <500MB | 500MB-1GB | >1GB |

For our homelab cluster, the 87MB database is fine. The issue was never database size —
it was the underlying disk latency making every operation slow.
