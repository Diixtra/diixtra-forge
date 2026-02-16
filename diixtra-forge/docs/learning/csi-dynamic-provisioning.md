# Learning: Container Storage Interface (CSI) and Dynamic Provisioning

## Level 1: Core Concept — The Storage Problem in Kubernetes

Containers are ephemeral by design. When a pod dies, its filesystem is gone.
But databases, file uploads, TLS certificates, and logs need to survive
pod restarts. This is the fundamental tension that CSI solves.

**Before CSI**: Every storage vendor wrote a custom "volume plugin" compiled
directly into Kubernetes. Adding a new storage backend meant recompiling
kubelet. Upgrading storage drivers meant upgrading Kubernetes itself. This
was unsustainable.

**After CSI**: A standard gRPC interface that any storage vendor can implement
as a standalone container. Kubernetes talks to the CSI driver via a Unix socket,
and the driver handles everything else. New storage backends are just new
containers — no Kubernetes recompilation needed.

## Level 2: The Three CSI Services

Every CSI driver implements three gRPC services:

### Identity Service (both controller + node)
"Who am I and what can I do?"
- `GetPluginInfo` — returns driver name (e.g., `org.democratic-csi.nfs`)
- `GetPluginCapabilities` — reports features (create volumes, expand, snapshot)
- `Probe` — health check

### Controller Service (runs as a Deployment, 1 replica)
"Create and manage volumes on the storage backend."
- `CreateVolume` — tells TrueNAS to create a ZFS dataset + NFS share
- `DeleteVolume` — removes the dataset and share
- `ControllerPublishVolume` — for iSCSI: creates a LUN mapping
- `CreateSnapshot` — ZFS snapshot
- `ControllerExpandVolume` — resize the dataset/zvol

This runs in the cluster but talks to TrueNAS over HTTPS. It never
touches the nodes directly.

### Node Service (runs as a DaemonSet, every node)
"Mount/unmount volumes on THIS specific node."
- `NodeStageVolume` — for iSCSI: runs `iscsiadm` to connect the LUN
- `NodePublishVolume` — mount the filesystem into the pod's directory
- `NodeUnpublishVolume` — unmount
- `NodeUnstageVolume` — for iSCSI: disconnect the LUN

This runs on every node because it needs host-level access to mount
filesystems and manage iSCSI sessions.

```
┌─────────────────────────────────────────────────────────────┐
│                    Kubernetes Cluster                        │
│                                                             │
│  ┌──────────────────────┐    ┌──────────────────────────┐   │
│  │  CSI Controller       │    │  kubelet (on each node)  │   │
│  │  (Deployment)         │    │                          │   │
│  │                       │    │  ┌────────────────────┐  │   │
│  │  CreateVolume ────────┼──┐ │  │ CSI Node Agent     │  │   │
│  │  DeleteVolume         │  │ │  │ (DaemonSet)        │  │   │
│  │  CreateSnapshot       │  │ │  │                    │  │   │
│  │  ExpandVolume         │  │ │  │ NodeStageVolume    │  │   │
│  └───────────┬───────────┘  │ │  │ NodePublishVolume  │  │   │
│              │              │ │  └─────────┬──────────┘  │   │
│              │ HTTPS API    │ │            │ mount/iscsi  │   │
│              ▼              │ │            ▼              │   │
│  ┌───────────────────────┐ │ │  ┌────────────────────┐   │   │
│  │  TrueNAS SCALE        │ │ │  │  Pod with PVC      │   │   │
│  │  10.2.0.232            │ │ │  │  /data mounted     │   │   │
│  │                       │◄┘ │  └────────────────────┘   │   │
│  │  ZFS datasets         │  │                            │   │
│  │  NFS shares           │  │                            │   │
│  │  iSCSI targets        │  └────────────────────────────┘   │
│  └───────────────────────┘                                   │
└─────────────────────────────────────────────────────────────┘
```

## Level 3: The Full Lifecycle of a PVC

Here's exactly what happens when you `kubectl apply` a PVC:

### Phase 1: Provisioning (Controller Service)
1. You create a PVC referencing `storageClassName: truenas-nfs`
2. The PV controller in kube-controller-manager sees the PVC
3. It finds the matching StorageClass, which names the CSI driver
4. It calls the CSI controller's `CreateVolume` RPC
5. democratic-csi receives the call and:
   a. Generates a volume name: `pvc-<uuid>`
   b. Calls TrueNAS API: `POST /api/v2.0/pool/dataset`
      with parent path `tank/k8s/nfs/vols/pvc-<uuid>`
   c. Calls TrueNAS API: `POST /api/v2.0/sharing/nfs`
      to create an NFS share for the new dataset
   d. Returns the volume ID and NFS mount details to Kubernetes
6. Kubernetes creates a PV bound to the PVC

### Phase 2: Attachment (Node Service)
7. A pod is scheduled that references the PVC
8. kubelet on the target node calls `NodeStageVolume`
   (for NFS, this is a no-op; for iSCSI, it runs `iscsiadm -m login`)
9. kubelet calls `NodePublishVolume`
   - For NFS: runs `mount -t nfs 10.2.0.232:/mnt/tank/k8s/nfs/vols/pvc-xxx /var/lib/kubelet/pods/<pod>/volumes/...`
   - For iSCSI: runs `mount /dev/sdX /var/lib/kubelet/pods/<pod>/volumes/...`
10. The pod sees the mounted filesystem at the specified `mountPath`

### Phase 3: Cleanup (reverse order)
11. Pod deleted → `NodeUnpublishVolume` (unmount)
12. PVC deleted (with reclaimPolicy: Delete):
    - `DeleteVolume` → TrueNAS API removes NFS share + ZFS dataset
    - PV deleted automatically

### The Sidecar Pattern
The CSI controller pod actually contains 5 containers, not just one:

```
Pod: truenas-nfs-democratic-csi-controller
├── csi-driver          ← The actual democratic-csi code
├── csi-provisioner     ← Watches PVCs, calls CreateVolume
├── csi-attacher        ← Handles ControllerPublish/Unpublish
├── csi-resizer         ← Watches PVC resize requests
└── csi-snapshotter     ← Handles VolumeSnapshot requests
```

The sidecars are Kubernetes SIG-Storage maintained containers that translate
Kubernetes events into CSI gRPC calls. This is the "sidecar pattern" — the
actual driver (democratic-csi) only needs to implement the gRPC interface,
and the sidecars handle all the Kubernetes-specific plumbing. This is why
CSI drivers are portable across orchestrators (Kubernetes, Nomad, Mesos).

## NFS vs iSCSI: What's Actually Happening on the Wire

### NFS (Network File System)
```
Pod writes file → VFS → NFS client (kernel) → RPC over TCP →
  → NFS server (TrueNAS) → ZFS → disk
```
- Operates at the **file** level (open, read, write, close)
- Multiple clients can mount the same export simultaneously
- Stateless (NFSv3) or stateful with delegation (NFSv4)
- Overhead: RPC encoding, network round-trips per operation

### iSCSI (Internet SCSI)
```
Pod writes file → VFS → ext4/xfs → block device (/dev/sdX) →
  → iSCSI initiator → TCP → iSCSI target (TrueNAS) → zvol → disk
```
- Operates at the **block** level (read/write sectors)
- Single client (initiator) owns the LUN exclusively
- Appears as a local disk to the operating system
- Lower overhead: no filesystem translation on the network path
- The LOCAL filesystem (ext4/xfs) runs on the Kubernetes node,
  not on TrueNAS. TrueNAS just provides raw blocks.

This is why iSCSI is faster for databases — the filesystem journal
is local, reducing network round-trips for metadata operations.
