# Media Stack Alert Runbook

Runbook for all media-stack monitoring alerts. Each alert links here via `runbook_url` annotation in Grafana.

**Host:** media-stack LXC (192.168.11.40)
**SSH:** `ssh root@192.168.11.40`
**Compose:** `/opt/media-stack/compose.yaml`
**Alloy:** `systemctl status alloy`

---

## MediaContainerDown

**Severity:** critical | **For:** 5m

**Symptoms:** One or more critical containers (Jellyfin, Radarr, Sonarr, Prowlarr, Decypharr) are not running.

**Triage:**
1. SSH to media-stack: `ssh root@192.168.11.40`
2. Check container status: `docker compose -f /opt/media-stack/compose.yaml ps`
3. Identify exited containers and check their logs: `docker logs <container>`

**Resolution:**
1. Restart all containers: `docker compose -f /opt/media-stack/compose.yaml up -d`
2. Check disk space: `df -h`
3. Check for OOM kills: `dmesg | grep -i oom`

**False positive?** Fires as a single alert if Alloy or cAdvisor is down (monitoring broken, not containers). Verify by SSHing in and checking `docker ps` directly.

---

## MediaContainerRestartLoop

**Severity:** warning | **For:** 5m

**Symptoms:** A container has restarted more than 3 times in the last hour.

**Triage:**
1. SSH to media-stack: `ssh root@192.168.11.40`
2. Check container status: `docker compose -f /opt/media-stack/compose.yaml ps`
3. Identify the restarting container and check its logs: `docker logs --tail 100 <container>`

**Resolution:**
1. Check for config errors in the container logs.
2. Check for OOM kills: `dmesg | grep -i oom`
3. Check if disk is full: `df -h`
4. Check for port conflicts: `ss -tlnp`

**False positive?** Can fire during planned updates or deployments when containers are intentionally restarted.

---

## RdAccountExpiringSoon

**Severity:** warning | **For:** 1h

**Symptoms:** Real-Debrid premium subscription expires in less than 15 days.

**Triage:**
1. Check the `rd_account_days_remaining` metric in Grafana.
2. Verify subscription status at https://real-debrid.com/premium

**Resolution:**
1. Renew the Real-Debrid subscription.
2. If the API key changes, update it in the SOPS vault and re-run Ansible.

**False positive?** The metric may be stale if the cron job that checks it has failed. Check whether the `RdExpiryCheckFailed` alert is also firing.

---

## RdAccountExpiryCritical

**Severity:** critical | **For:** 30m

**Symptoms:** Real-Debrid premium subscription expires in less than 5 days. Debrid content will stop working.

**Triage:**
1. Check the `rd_account_days_remaining` metric in Grafana.
2. Verify subscription status at https://real-debrid.com/premium

**Resolution:**
1. Urgent renewal required. Without premium, all debrid-sourced content becomes unavailable.
2. If the API key changes, update it in the SOPS vault and re-run Ansible.

**False positive?** The metric may be stale if the cron job that checks it has failed. Check whether the `RdExpiryCheckFailed` alert is also firing.

---

## RdExpiryCheckFailed

**Severity:** warning | **For:** 6h

**Symptoms:** The daily RD API check script has been failing for 6+ hours.

**Triage:**
1. SSH to media-stack: `ssh root@192.168.11.40`
2. Run the script manually: `/opt/media-stack/rd-expiry-check.sh`
3. Check the output and exit code.
4. Inspect the textfile output: `cat /var/lib/alloy/textfile/rd_expiry.prom`

**Resolution:**
1. Check network connectivity: `curl -sf https://api.real-debrid.com/rest/1.0/user`
2. Verify the API key is valid.
3. Ensure `jq` is installed: `which jq`

**False positive?** The script may have run successfully but the textfile was not picked up by Alloy. Check Alloy status: `systemctl status alloy`.

---

## RdFuseMountDown

**Severity:** critical | **For:** 10m

**Symptoms:** `/mnt/debrid` FUSE mount is inaccessible. Jellyfin playback for all debrid content is broken.

**Triage:**
1. SSH to media-stack: `ssh root@192.168.11.40`
2. Check mount status: `mountpoint /mnt/debrid`
3. List mount contents: `ls /mnt/debrid/`
4. Check Decypharr logs: `docker logs decypharr --tail 50`

**Resolution:**
1. Restart Decypharr: `cd /opt/media-stack && docker compose restart decypharr`
2. If mount is still broken: `mount --make-rshared /` then `docker compose restart decypharr`
3. Check if the RD API key is valid.

**False positive?** Brief mount interruption during a Decypharr restart. Wait for the 10m `for` duration to elapse before investigating.

---

## JellyfinTranscodingErrors

**Severity:** warning | **For:** 5m

**Symptoms:** More than 5 transcoding/FFmpeg errors in 15 minutes.

**Triage:**
1. SSH to media-stack: `ssh root@192.168.11.40`
2. Check Jellyfin logs for transcoding errors: `docker logs jellyfin --tail 200 | grep -i 'transcode\|ffmpeg\|error'`
3. Check GPU passthrough: `docker exec jellyfin ls -la /dev/dri/`

**Resolution:**
1. Check if HEVC/AV1 encoding is disabled (Radeon 760M does not support it).
2. Check tmpfs space: `df -h | grep transcodes`
3. Restart Jellyfin: `cd /opt/media-stack && docker compose restart jellyfin`

**False positive?** Codec-specific errors for unsupported formats are expected for some content and may not indicate a real problem.

---

## DecypharrRdApiErrors

**Severity:** warning | **For:** 5m

**Symptoms:** More than 10 RD API errors or rate limits in 15 minutes.

**Triage:**
1. SSH to media-stack: `ssh root@192.168.11.40`
2. Check Decypharr logs: `docker logs decypharr --tail 200 | grep -iE 'error|rate.limit|429'`
3. Check Real-Debrid status page for outages.

**Resolution:**
1. If rate-limited, wait. The RD rate limit is 250 requests/minute.
2. If receiving 401/403 errors, check the API key.
3. If network errors, check DNS and connectivity.

**False positive?** Brief API blips during Real-Debrid maintenance windows.

---

## MediaStackDiskUsage

**Severity:** warning | **For:** 15m

**Symptoms:** LXC root disk (256GB) is more than 85% full.

**Triage:**
1. SSH to media-stack: `ssh root@192.168.11.40`
2. Check overall disk usage: `df -h /`
3. Check config sizes: `du -sh /opt/media-stack/config/*`
4. Check Docker disk usage: `docker system df`

**Resolution:**
1. Prune Docker: `docker system prune -a`
2. Check log rotation: `ls -lh /var/lib/docker/containers/*/`
3. Check Jellyfin metadata size: `du -sh /opt/media-stack/config/jellyfin/`
4. Check Alloy WAL size: `du -sh /var/lib/alloy/data/`

**False positive?** Unlikely. Disk usage is a fact.
