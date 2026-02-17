# TrueNAS SCALE Setup for Kubernetes Storage

This guide prepares your TrueNAS SCALE instance to provide dynamic storage
provisioning to your Kubernetes cluster via democratic-csi.

**TrueNAS IP:** 10.2.0.232 (Kaznet VLAN)

---

## Step 1: Enable Required Services

In the TrueNAS Web UI (https://10.2.0.232):

### NFS
1. Go to **System → Services**
2. Find **NFS** → click the pencil icon
3. Enable **NFSv3 ownership model for NFSv4** (democratic-csi needs this)
4. Optionally bind to `10.2.0.232` under "Bind IP Addresses" (restricts NFS to Kaznet VLAN only)
5. Toggle the service **ON** and enable **Start Automatically**

### iSCSI
1. Go to **System → Services**
2. Find **iSCSI** → toggle **ON** and enable **Start Automatically**
3. Click the pencil icon:
   - Note the **Base Name** (usually `iqn.2005-10.org.freenas.ctl`)
   - Under **Portals**, verify a portal exists on `0.0.0.0:3601` (or create one)
   - Note the **Portal ID** (usually `1` — but check via API, the WebUI can be wrong)

> **Important**: To verify the portal ID, use the TrueNAS API:
> ```
> curl -k -H "Authorization: Bearer YOUR_API_KEY" \
>   https://10.2.0.232/api/v2.0/iscsi/portal | python3 -m json.tool
> ```
> Look for the `id` field in the response. Use THIS value, not what the WebUI shows.

### SSH (optional — only needed for SSH-based drivers, not API-based)
Not required for our setup. We're using the **API driver** which talks to
TrueNAS over HTTPS, not SSH.

---

## Step 2: Create ZFS Datasets

democratic-csi needs parent datasets where it will create child datasets
(one per PVC). It also needs separate datasets for snapshots.

Go to **Datasets** and create this structure:

```
your-pool/
└── k8s/
    ├── nfs/
    │   ├── vols      ← NFS volumes land here
    │   └── snaps     ← NFS snapshots land here
    └── iscsi/
        ├── vols      ← iSCSI zvols land here
        └── snaps     ← iSCSI snapshots land here
```

To create these:
1. Go to **Datasets**
2. Select your pool (e.g., `tank` or `main-pool`)
3. Click **Add Dataset** → Name: `k8s` → Save
4. Select `k8s` → **Add Dataset** → Name: `nfs` → Save
5. Select `nfs` → **Add Dataset** → Name: `vols` → Save
6. Select `nfs` → **Add Dataset** → Name: `snaps` → Save
7. Select `k8s` → **Add Dataset** → Name: `iscsi` → Save
8. Select `iscsi` → **Add Dataset** → Name: `vols` → Save
9. Select `iscsi` → **Add Dataset** → Name: `snaps` → Save

> **Note the full paths** — you'll need them. They should look like:
> `tank/k8s/nfs/vols`, `tank/k8s/nfs/snaps`, `tank/k8s/iscsi/vols`, `tank/k8s/iscsi/snaps`
>
> Replace `tank` with your actual pool name.

**Do NOT manually create NFS shares for these datasets.** democratic-csi
will create and manage NFS shares automatically for each PVC via the API.

---

## Step 3: Create a TrueNAS API Key

1. In the TrueNAS Web UI, click the **Admin** user icon (top right)
2. Go to **API Keys**
3. Click **Add** → Name: `democratic-csi` → **Save**
4. **Copy the key immediately** — it won't be shown again

---

## Step 4: Store the API Key in 1Password

In 1Password:
1. Go to the **Homelab** vault
2. Create a new item:
   - **Type**: API Credential (or Password)
   - **Title**: `truenas-api-key`
   - **credential** field: paste the API key from Step 3
3. Save

The 1Password Operator will sync this to a Kubernetes Secret automatically
via the OnePasswordItem resource in our manifests.

---

## Step 5: Install NFS/iSCSI Utilities on Kubernetes Nodes

Each Kubernetes node needs client utilities to mount the storage.

### On Debian/Ubuntu nodes (kaz-k8-1, k8-worker-1):
```bash
sudo apt-get update
sudo apt-get install -y nfs-common open-iscsi lsscsi sg3-utils multipath-tools scsitools
sudo systemctl enable --now iscsid
sudo systemctl enable --now multipathd
```

### On Raspberry Pi nodes (pi4, pi5):
```bash
sudo apt-get update
sudo apt-get install -y nfs-common open-iscsi
sudo systemctl enable --now iscsid
```

> **Why these packages?**
> - `nfs-common` — NFS client for mounting NFS shares into pods
> - `open-iscsi` — iSCSI initiator for block storage connections
> - `multipath-tools` — Optional, enables multipath I/O (multiple paths to same volume)
> - The iSCSI initiator daemon (`iscsid`) must be running BEFORE pods try to mount

### Verify:
```bash
# NFS client ready?
showmount -e 10.2.0.232    # Should show exports (may be empty initially)

# iSCSI initiator ready?
cat /etc/iscsi/initiatorname.iscsi   # Should show iqn.YYYY-MM...
sudo iscsiadm -m discovery -t sendtargets -p 10.2.0.232   # Should connect
```

---

## Step 6: Deploy via Flux

Once the above is complete, Flux will deploy democratic-csi automatically
from the manifests in this repo. The dependency chain ensures:

1. `infrastructure` Kustomization deploys democratic-csi namespace + HelmReleases
2. 1Password Operator syncs the `Truenas API Credential` item → `truenas-api-key` K8s Secret
3. democratic-csi controllers start and connect to TrueNAS at 10.2.0.232
4. StorageClasses become available (`truenas-nfs` and `truenas-iscsi`)
5. Any PVC referencing these StorageClasses gets auto-provisioned

---

## Troubleshooting

### democratic-csi controller won't start
```bash
kubectl logs -n democratic-csi deploy/truenas-nfs-democratic-csi-controller -c csi-driver
```
Common causes:
- API key wrong or expired
- TrueNAS not reachable from cluster (check: `kubectl run test --rm -it --image=busybox -- wget -qO- https://10.2.0.232/api/v2.0/system/version`)
- Dataset paths don't exist

### PVC stuck in Pending
```bash
kubectl describe pvc <name>
kubectl logs -n democratic-csi deploy/truenas-nfs-democratic-csi-controller -c csi-driver
```
Common causes:
- StorageClass name mismatch
- NFS/iSCSI service not running on TrueNAS
- Node missing `nfs-common` or `open-iscsi` packages

### iSCSI volumes won't attach
```bash
# On the node where the pod is scheduled:
sudo iscsiadm -m session    # Show active sessions
sudo journalctl -u iscsid   # Check iSCSI daemon logs
```

### TrueNAS 25+ API version issue
TrueNAS 25 changed the API version string (no longer returns "SCALE").
If the controller crashes, add this to the HelmRelease values:
```yaml
controller:
  driver:
    image:
      tag: next
```
