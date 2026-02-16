# ADR-006: TrueNAS Dynamic Storage via democratic-csi

## Status
Accepted

## Context
Kubernetes workloads need persistent storage that survives pod restarts,
rescheduling, and node failures. The cluster currently uses `emptyDir`
which is ephemeral and node-local. Options considered:

1. **Local PVs** — bind to specific nodes, no mobility
2. **Longhorn** — distributed storage across nodes, requires dedicated disks
3. **Rook/Ceph** — enterprise-grade, heavy resource overhead
4. **democratic-csi + TrueNAS** — leverages existing NAS infrastructure

## Decision
Use **democratic-csi** with the **freenas-api** driver (NFS + iSCSI) against
TrueNAS SCALE at 10.2.0.232.

Rationale:
- TrueNAS SCALE already exists in the homelab with ZFS pools
- API driver (not SSH) — cleaner, no SSH key management
- ZFS provides snapshots, clones, compression, checksums for free
- Two protocols cover all use cases (NFS for shared, iSCSI for databases)
- democratic-csi is the officially recommended CSI driver by iXsystems
- Dynamic provisioning eliminates manual volume management entirely

## Architecture
```
PVC request → StorageClass → democratic-csi controller
    → TrueNAS API (HTTPS) → ZFS dataset/zvol created
    → NFS share or iSCSI target configured
    → democratic-csi node agent mounts into pod
```

## Dataset Structure
```
<pool>/k8s/
├── nfs/
│   ├── vols/    ← child datasets auto-created per NFS PVC
│   └── snaps/   ← detached snapshots
└── iscsi/
    ├── vols/    ← zvols auto-created per iSCSI PVC
    └── snaps/   ← detached snapshots
```

## Security
- TrueNAS API key stored in 1Password, synced via Operator
- HTTPS with self-signed cert (allowInsecure: true for internal traffic)
- NFS restricted to Kaznet VLAN (10.2.0.0/24)
- iSCSI portal on dedicated port 3260

## Consequences
- **Pro**: Zero-touch volume lifecycle — create PVC, get storage
- **Pro**: ZFS snapshots enable backup/restore via VolumeSnapshots
- **Pro**: NFS supports ReadWriteMany for shared workloads
- **Con**: Single point of failure (TrueNAS host)
- **Con**: Network latency vs local storage (acceptable for homelab)
- **Con**: Requires NFS/iSCSI client packages on all nodes
