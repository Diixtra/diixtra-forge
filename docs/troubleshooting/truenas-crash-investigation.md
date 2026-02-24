# TrueNAS Crash Investigation (KAZ-90)

**Date**: 2026-02-24
**Status**: Open — root cause not yet confirmed
**Impact**: Repeated TrueNAS crashes knock out iSCSI and NFS storage, causing pod volume mount failures and Flux reconciliation failures. Concurrent DiskPressure events on worker nodes compounded the impact.

## Environment

- **TrueNAS VM**: 5 CPU cores, 20GB RAM, 30TB storage (Proxmox)
- **k3s cluster**: Consumes iSCSI and NFS storage from TrueNAS via democratic-csi
- **Proxmox host**: Shared between TrueNAS VM and k3s node VMs

## Timeline (from audit logs)

Audit data begins Feb 17. System was running normally from Feb 17 through Feb 19 23:50 with no boot events.

| Timestamp | Event | Type |
|-----------|-------|------|
| Feb 19 23:50 | System boot | Cold boot (no preceding shutdown) |
| Feb 19 23:57 | `shutdown -r now` | **Intentional reboot** |
| Feb 19 23:58 | System boot | Expected restart |
| Feb 20 13:44 | System boot | **Unplanned** — no shutdown logged |
| Feb 21 00:20 | System boot | **Unplanned** — no shutdown logged |
| Feb 24 02:46 | Last audit event | System went silent |
| Feb 24 13:59 | System boot | **Unplanned** — 11h gap |

**5 boots in 7 days. Only 1 intentional.**

## Audit Log Analysis

### What the logs show

- **22,401 events** across Feb 17-24 (3 CSV files, ~10MB)
- **Event types**: CREDENTIAL (5,792), GENERIC (16,389), LOGIN (219), ESCALATION (1)
- **Zero error events**: No failures, denied access, or rejected operations
- **Zero iSCSI events**: No target drops, initiator disconnects, or SCST errors
- **Zero ZFS events**: No pool errors, scrub issues, or degraded state
- **1 ANOM_ABEND**: Gunicorn worker crash in Docker container (UID=apps) — not system-level

### Key finding: ~154 Docker containers

154 unique veth interfaces detected, suggesting approximately 154 Docker containers running TrueNAS apps (exact count may differ due to shared network namespaces or stale interfaces from crashed containers). Each boot generates heavy iptables/netfilter activity as Docker recreates networking rules.

### Pre-crash pattern

Events before every crash are **identical**: routine CREDENTIAL polling (~1/min from the TrueNAS web UI). No anomaly, no error, no escalation. The system simply stops producing audit events.

### What the audit log does NOT capture

- Kernel panics / OOM kills
- ZFS pool errors
- iSCSI target failures
- dmesg / syslog entries
- Proxmox hypervisor events

## Hypotheses

Ranking is provisional — pending Proxmox host log analysis and TrueNAS kernel logs.

### 1. Proxmox host-level issue

The crashes leave zero trace in TrueNAS audit logs, suggesting the VM may be killed externally. Possible causes:
- Proxmox OOM killer targeting the TrueNAS VM
- Proxmox storage backend issue affecting the VM disk
- CPU/memory overcommit on the Proxmox host

**Evidence for**: No warning in TrueNAS logs before crash. Clean cold boot each time.
**Next step**: Check Proxmox host `dmesg`, `journalctl`, and VM resource usage graphs.

### 2. Kernel panic from Docker container pressure

~154 Docker containers generate significant kernel memory pressure (network namespaces, iptables rules, cgroup allocations). A kernel panic would not appear in audit logs.

**Evidence for**: ~154 containers is a high count for a NAS appliance. Heavy netfilter activity observed.
**Next step**: Check `journalctl -k -b -1` on TrueNAS for panic traces from the previous boot. Review Docker container list and consider reducing count.

### 3. ZFS memory pressure

ZFS ARC cache can consume large amounts of RAM. Combined with ~154 Docker containers and TrueNAS middleware, 20GB may not be sufficient.

**Evidence for**: ZFS ARC is known to cause memory pressure. 20GB with ~154 containers and ZFS is tight.
**Next step**: Check `arc_summary` and ZFS ARC size after boot. Monitor memory usage over time.

## Required Data (not available in audit export)

To confirm root cause, we need:

1. **TrueNAS system logs**: `journalctl -b -1` (previous boot) or `/var/log/syslog`
2. **TrueNAS kernel logs**: `journalctl -k -b -1` (check for panic/OOM)
3. **Proxmox host logs**: `dmesg` and `journalctl` from the Proxmox node
4. **Proxmox VM metrics**: CPU, memory, I/O graphs for the TrueNAS VM over the crash period
5. **ZFS ARC stats**: `cat /proc/spl/kstat/zfs/arcstats` or `arc_summary`
6. **Docker container list**: `docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Size}}"` on TrueNAS

## Immediate Mitigations

1. **Reduce Docker containers**: Audit the ~154 containers on TrueNAS. Disable non-essential apps.
2. **Increase VM memory**: Consider bumping from 20GB to 32GB if Proxmox host allows.
3. **Cap ZFS ARC**: Set `zfs_arc_max` to ~40% of total RAM (e.g., 8GB of 20GB) to leave headroom for Docker containers, TrueNAS middleware, and iSCSI/NFS services. Adjust proportionally if VM memory changes.
4. **Verify Proxmox VM auto-restart**: Ensure TrueNAS VM has `Start at boot` enabled with appropriate startup order. Consider a Proxmox-level watchdog or monitoring script to detect and restart the VM on crash.
5. **Add monitoring**: Expose TrueNAS VM metrics to Grafana Cloud for proactive alerting.
6. **Cross-reference cluster recovery**: See `docs/runbooks/disaster-recovery.md` for k3s cluster recovery steps following TrueNAS outages.
