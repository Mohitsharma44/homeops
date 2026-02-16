# Talos Node Provisioning

Step-by-step instructions for provisioning bare metal Talos nodes with Sidero Omni.

## Node Inventory

| Node | IP | Hardware | RAM |
|------|-----|----------|-----|
| talos01 | 192.168.11.19 | AMD Ryzen 7 7735HS | 16GB |
| talos02 | 192.168.11.21 | AMD Ryzen 7 7735HS | 16GB |
| talos03 | 192.168.11.22 | AMD Ryzen 7 7735HS | 16GB |

## Omni Instance

- **URL**: https://omni.sharmamohit.com:8090
- **Managed by**: Docker host `omni` (192.168.11.30) via Komodo

## Talos Configuration

- **Version**: v1.12.0
- **Extensions**: amd-ucode, iscsi-tools, util-linux-tools

## Prerequisites

- [Sidero Omni](https://www.siderolabs.com/omni/) account and instance running
- `omnictl` CLI installed and authenticated
- USB drives for booting installation media
- Bare metal machines with network access

## Problem: Duplicate Hardware UUIDs

These bare metal machines report incomplete BIOS UUIDs (`03000200-0400-0500`), which Talos autocompletes to identical values (`03000200-0400-0500-0006-000700080009`), preventing multiple machines from registering in Omni.

## Solution: Pre-set Unique UUIDs via INSTALLER_META_BASE64

Use Omni's `omnictl download` with custom kernel arguments to embed unique UUIDs in the META partition at boot time.

### Generate Base64-encoded META

For each machine, create a unique UUID and encode it:

```bash
# Machine 1 (192.168.11.19)
echo -n "0xf=03000200-0400-0500-0019-000000000019" | gzip -9 | base64
# Output: H4sIAHLxVWkCAzOoSLM1MDYwMDAyMDA1MAERpiDCwNASSMCAoSUAcTCVBSgAAAA=

# Machine 2 (192.168.11.21)
echo -n "0xf=03000200-0400-0500-0021-000000000021" | gzip -9 | base64
# Output: H4sIADfyVWkCAzOoSLM1MDYwMDAyMDA1MAERpiDCwMgQSMCAkSEAz59HAigAAAA=

# Machine 3 (192.168.11.22)
echo -n "0xf=03000200-0400-0500-0022-000000000022" | gzip -9 | base64
# Output: H4sIAJTxVWkCAzOoSLM1MDYwMDAyMDA1MAERpiDCwMgISMCAkREArusv5ygAAAA=
```

### Download Omni ISOs with UUID Override

```bash
# Machine 1
omnictl download iso --arch amd64 \
  --talos-version 1.12.0 \
  --extensions amd-ucode --extensions iscsi-tools --extensions util-linux-tools \
  --extra-kernel-args "talos.environment=INSTALLER_META_BASE64=H4sIAHLxVWkCAzOoSLM1MDYwMDAyMDA1MAERpiDCwNASSMCAoSUAcTCVBSgAAAA=" \
  --output omni-talos01.iso

# Machine 2
omnictl download iso --arch amd64 \
  --talos-version 1.12.0 \
  --extensions amd-ucode --extensions iscsi-tools --extensions util-linux-tools \
  --extra-kernel-args "talos.environment=INSTALLER_META_BASE64=H4sIADfyVWkCAzOoSLM1MDYwMDAyMDA1MAERpiDCwMgQSMCAkSEAz59HAigAAAA=" \
  --output omni-talos02.iso

# Machine 3
omnictl download iso --arch amd64 \
  --talos-version 1.12.0 \
  --extensions amd-ucode --extensions iscsi-tools --extensions util-linux-tools \
  --extra-kernel-args "talos.environment=INSTALLER_META_BASE64=H4sIAJTxVWkCAzOoSLM1MDYwMDAyMDA1MAERpiDCwMgISMCAkREArusv5ygAAAA=" \
  --output omni-talos03.iso
```

## Provisioning Steps

### 1. Write ISO to USB Drive

```bash
# Find USB device
diskutil list

# Write ISO (replace diskX with your USB device)
sudo dd if=/tmp/omni-talos01.iso of=/dev/rdiskX bs=1m status=progress
```

### 2. Boot Machine from USB

- Insert USB drive into target machine
- Boot from USB (F12/F11/DEL for boot menu depending on motherboard)
- Machine will boot into Talos maintenance mode

### 3. Verify Machine Registration in Omni

Machine should appear in Omni UI under "Machines" with:
- Unique UUID (e.g., `03000200-0400-0500-0019-000000000019`)
- Full hardware details (CPU, memory, storage, network)
- Connected status

### 4. Add Machine to Cluster

**Create New Cluster:**
1. In Omni UI: Clusters > Create Cluster
2. Select machine from available pool
3. Configure Kubernetes version and cluster settings
4. Click "Create" — Omni will install Talos to disk

**Add to Existing Cluster:**
1. Select existing cluster
2. Click "Add Machine"
3. Select machine from available pool
4. Confirm — Omni will install and join to cluster

### 5. Monitor Installation

- Watch installation progress in Omni UI or machine console
- Installation typically takes 2-5 minutes
- Machine will reboot automatically after installation

### 6. Verify Cluster Membership

After reboot, verify in Omni UI:
- Machine shows as cluster member
- Status: Ready
- Kubernetes node appears in cluster

## Adding More Machines

For each additional machine:

1. Generate unique UUID: `03000200-0400-0500-00XX-0000000000XX` (replace XX with machine identifier)
2. Encode UUID: `echo -n "0xf=<UUID>" | gzip -9 | base64`
3. Download ISO: `omnictl download iso --extra-kernel-args "talos.environment=INSTALLER_META_BASE64=<base64>"`
4. Follow provisioning steps above

## Troubleshooting

### Machine Not Appearing in Omni

- Verify network connectivity (machine must reach Omni instance)
- Check firewall rules allow WireGuard (UDP 50000, gRPC tunnel if configured)
- Confirm machine booted from correct ISO

### Duplicate UUID Error

- Verify ISO was generated with unique `INSTALLER_META_BASE64`
- Check base64 string has no spaces or line breaks
- Regenerate ISO if needed

### Hardware Details Show as Null

This indicates the machine was provisioned without Omni certificates. Re-provision using the ISOs generated above with `omnictl download`.

## Technical Details

- **META Partition Key 0xf:** UUID override field in Talos
- **INSTALLER_META_BASE64:** Kernel argument to inject META values at boot
- **Format:** `echo -n "0x[key]=[value]" | gzip -9 | base64`

## References

- [Talos Metal Network Configuration](https://docs.siderolabs.com/talos/v1.8/networking/metal-network-configuration/)
- [Omni Installation Media with Initial Labels](https://omni.siderolabs.com/how-to-guides/how-to-set-initial-machine-labels)
- [Talos GitHub Issue #9400 - UUID Override](https://github.com/siderolabs/talos/issues/9400)
- [Omni GitHub Issue #38 - Secure Join Tokens](https://github.com/siderolabs/omni/issues/38)
