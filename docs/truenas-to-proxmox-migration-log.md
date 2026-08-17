# TrueNAS → Proxmox Migration Log

**Date:** 2026-03-14
**Server:** Dell R720XD (256GB RAM, 14 drives, iDRAC 12G)
**Operator:** Claude Code + Mohit Sharma
**Estimated Duration:** 2–4 hours

---

## Pre-flight

- [x] Migration runbook reviewed and refined (`truenas-to-proxmox-migration.md`)
- [x] Ansible playbook scaffolded (`proxmox/`)
- [x] Ansible vault secrets created
- [x] Full recon completed via SSH to TrueNAS
- [x] SeaweedFS VM internals inspected
- [x] Frigate NVR stopped on pve (VM 101)
- [x] iDRAC access verified (192.168.10.185, Redfish API functional)

---

## PHASE 1: Pre-migration (TrueNAS via SSH)

**SSH Target:** `admin@192.168.11.15`
**Start time:** 2026-03-14 ~20:05 UTC

| Step | Description | Status | Notes |
|------|-------------|--------|-------|
| 1.1 | Read-only inventory | ✅ | 4 pools ONLINE, 0 errors, NFS + SSH running, SeaweedFS VM running |
| 1.2 | Stop SeaweedFS VM | ✅ | Graceful stop timed out; user force-stopped. VM confirmed STOPPED |
| 1.3 | Pre-migration ZFS snapshots | ✅ | `pool0@pre-migration-20260314-200758` and `ssdpool0@pre-migration-20260314-200758` (46 snapshots total). Required `sudo` — admin user lacks ZFS snapshot perms |
| 1.4 | Stop NFS and services (NOT SSH) | ✅ | NFS stopped. Only SSH remains running |
| 1.5 | Export pool0 and ssdpool0 | ✅ | Both exported via middleware (async jobs). pool0 took ~90s, ssdpool0 ~60s. Only boot-pool + ssdpool1 remain |
| 1.6 | Identify boot drives | ✅ | sdf (Crucial MX500, 1806E10DAE7F) + sdk (Samsung 870 EVO, S6PXNZ0T415298F) |
| 1.7 | Graceful shutdown | ✅ | SSH dropped as expected. Server is powered off |

### Network Configuration (captured before shutdown)

TrueNAS was using LACP bonding — **your switch must support 802.3ad for bonding to work on Proxmox**.

| Interface | MAC | Role |
|-----------|-----|------|
| eno1 (enp1s0f0) | 14:18:77:56:f0:59 | Unused (DOWN) |
| eno2 (enp1s0f1) | 14:18:77:56:f0:5b | bond0 slave (LACP) |
| eno3 (enp1s0f2) | 14:18:77:56:f0:5d | bond0 slave (LACP) |
| eno4 (enp1s0f3) | 14:18:77:56:f0:5f | bond0 slave (LACP) |

- **Bond mode:** 802.3ad (LACP), layer2+3 hash
- **Speed:** 3x 1Gbps
- **Proxmox installer:** Select a single NIC (e.g., eno2). Configure bond post-install

## PHASE 2: Proxmox Installation (Manual via iDRAC)

**Operator:** Mohit (manual)

| Step | Description | Status | Notes |
|------|-------------|--------|-------|
| 2.0 | Break LACP on switch for nic2 | ✅ | nic6 (f0:5f) used for install. nic2+nic4 left in LACP |
| 2.1 | Mount Proxmox ISO via iDRAC | ✅ | Mohit handled manually |
| 2.2 | Install Proxmox on sdj (Crucial) | ✅ | PVE 9.1.1, single disk (not mirror — will add mirror later). NIC names: nic0-nic7 (not eno*) |
| 2.3 | Eject ISO, reboot | ✅ | |
| 2.4 | Verify SSH to new Proxmox | ✅ | SSH OK, DNS fixed (8.8.8.8 → 192.168.11.1 + 9.9.9.9) |
| 2.5 | Configure LACP bond | ✅ | bond0 (nic2+nic4+nic6) 802.3ad layer2+3, 3x1Gbps active, LACP negotiated with switch |

## PHASE 3: Post-install Proxmox Setup

**SSH Target:** `root@192.168.11.15`

| Step | Description | Status | Notes |
|------|-------------|--------|-------|
| 3.1 | Verify Proxmox installation | ✅ | PVE 9.1.1 (Trixie), kernel 6.17.2-1-pve |
| 3.2 | Import pool0 and ssdpool0 | ✅ | Both ONLINE, zero errors. Clean import (no -f needed) |
| 3.3 | Audit and strip TrueNAS ACLs | ✅ | posixacl set, atime=off, xattr=sa, zvols skipped |
| 3.4 | Run Ansible playbook | ✅ | 6 attempts (fixed: enterprise repos, sanoid dir, apt-key deprecation, alloy override dir). Final: 75 ok, 0 failed |
| 3.5 | Fix ZFS ARC | ✅ | 192GB (was 16GB default). modprobe + initramfs updated |
| 3.6 | Disable enterprise repos | ✅ | pve-enterprise.sources + ceph.sources disabled (Trixie uses .sources format) |
| 3.7 | LACP bond configured | ✅ | bond0 (nic2+nic4+nic6) 802.3ad, 3x1Gbps |

## PHASE 4: SeaweedFS VM Migration

**SSH Target:** `root@192.168.11.15` then `mohitsharma44@192.168.11.133`

| Step | Description | Status | Notes |
|------|-------------|--------|-------|
| 4.1 | Register ssdpool0 as PVE storage | ✅ | Done via Ansible (Phase 3) |
| 4.2 | Pre-rename snapshot + ZFS holds | ✅ | `pre-rename-20260314-215431` on both zvols, migration-safety holds active |
| 4.3 | Rename zvols to Proxmox convention | ✅ | `seaweedfs-ojjxf` → `vm-200-disk-0`, `seaweedfs/seaweedVol` → `vm-200-disk-1`. Properties match exactly |
| 4.4 | Create QEMU VM 200 | ✅ | Hit encryption issue — pools had aes-256-gcm encryption. User had backup keys. EFI disk on local-lvm (ssdpool0 encrypted, can't create new zvols without key) |
| 4.5 | Boot VM, verify SSH | ✅ | VM booted, SSH OK at 192.168.11.133 (DHCP via preserved MAC). High load on initial boot (SeaweedFS cache warmup) |
| 4.6 | Verify SeaweedFS data and services | ✅ | All containers healthy. 4 S3 buckets intact (thanos-metrics, loki-chunks, loki-ruler, tempo-traces). 491GB data preserved. Komodo periphery running |
| 4.7 | Verify ZFS hold protection | ✅ | `zfs destroy` correctly blocked: "it's being held" |
| 4.8 | Configure auto-unlock for encrypted pools | ✅ | Key files at `/etc/zfs/keys/{pool0,ssdpool0}.key`, keylocation set to file:// |

## PHASE 5: Monitoring Setup

| Step | Description | Status | Notes |
|------|-------------|--------|-------|
| 5.1 | Verify Alloy + smartctl-exporter (via Ansible) | ✅ | Both active. Alloy getting 404s from Prometheus/Loki (ingress config issue, not migration-related) |

## PHASE 6: Validation & Cleanup

| Step | Description | Status | Notes |
|------|-------------|--------|-------|
| 6.1 | Full system validation | ✅ | All pools ONLINE, NFS exported, Sanoid timer active, VM 200 running |
| 6.2 | Fix ZFS mountpoints | ✅ | Pools imported without `/mnt` prefix. Fixed: `zfs set mountpoint=/mnt/pool0 pool0` and same for ssdpool0 |
| 6.3 | Restart Frigate on pve | ✅ | VM 101 started, NFS mounted at `/media/frigate` (379G data), Frigate container running |

---

## Timeline

| Time | Event |
|------|-------|
| | Migration started |

---

## Issues Encountered

1. **SeaweedFS VM graceful stop timed out** — Had to force-stop via TrueNAS UI. Docker containers with restart policies may have delayed bhyve shutdown.
2. **ZFS snapshot permissions** — `admin` user on TrueNAS lacks ZFS snapshot permissions. Required `sudo` for `zfs snapshot -r`.
3. **TrueNAS middleware shutdown failed silently** — `midclt call system.shutdown` returned but server stayed up. Used `sudo shutdown -h now` instead.

---

## Decisions Made During Migration

1. **LACP bond breakout** — Removed only eno2 from switch LAG for Proxmox install. eno3+eno4 left in LACP (no server responding, harmless). Will reconfigure bond post-install.
2. **Frigate stays on pve** — Coral TPU cannot be installed in R720XD. Frigate VM remains on pve (192.168.11.13) with NFS mount from r720xd:/mnt/pool0/nvr. No VM migration planned.
3. **PDM skipped** — Proxmox Datacenter Manager evaluated and rejected. Overkill for 2 nodes; `qm remote-migrate` or backup/restore sufficient if ever needed.
4. **Encrypted pools** — Both pool0 and ssdpool0 have aes-256-gcm encryption (set in TrueNAS). Keys recovered from user's backup. Auto-unlock configured via `/etc/zfs/keys/` key files with `keylocation=file://`.

---

## Post-Migration Notes

### Completed (2026-03-14)
- TrueNAS → Proxmox migration fully operational
- SeaweedFS VM running with all 4 S3 buckets intact (491GB)
- Frigate NVR restored from `/root/frigate/config/` backup (config was at default template, real config was in old mount path)
- LACP bond (nic2+nic4+nic6) 3x1Gbps active
- Alloy + smartctl-exporter sending metrics/logs to Prometheus/Loki
- ZFS auto-unlock configured via `/etc/zfs/keys/`
- Sanoid snapshot automation active
- NFS export working for Frigate

### TODO (follow-up session)
- [ ] **Boot drive mirror** — Proxmox installed on single Crucial MX500 (sdj) with LVM/ext4 (not ZFS). Adding mirror requires mdadm RAID1 under LVM. Three unused 500GB Samsung 870 EVOs available (sda, sdd, sdk). Not urgent — boot drive is rebuildable via Ansible, critical data is on raidz1 pools.
- [ ] **Alloy instance label** — currently `r720xd`, verify Grafana dashboards pick it up (was `truenas` before)
- [ ] **Clean up TrueNAS-era datasets** — `.ix-virt`, `.system`, `ix-applications` datasets on pool0/ssdpool0 are TrueNAS leftovers. Safe to remove after migration stable.
- [ ] **Commit homeops changes** — proxmox/ directory, updated migration runbook, migration log
- [ ] **ssdpool1** — still importable on the system. Decide whether to wipe those 2x1TB Samsung drives and repurpose them
