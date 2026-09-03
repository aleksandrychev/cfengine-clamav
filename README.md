# cfengine-clamav

[![CI](https://github.com/aleksandrychev/cfengine-clamav/actions/workflows/ci.yml/badge.svg)](https://github.com/aleksandrychev/cfengine-clamav/actions/workflows/ci.yml)

CFEngine build module that installs [ClamAV](https://www.clamav.net/) from upstream packages, keeps its signatures fresh, runs periodic scans, and reports the results as CFEngine Enterprise inventory.

![Mission Portal inventory](https://raw.githubusercontent.com/aleksandrychev/cfengine-clamav/main/inventory.png)

## What it does

- Installs the upstream ClamAV `.deb`/`.rpm` from clamav.net (Debian/Ubuntu and RHEL-family, x86_64/aarch64) and creates the `clamav` user.
- Runs `freshclam` when signatures are older than 2 days (configurable).
- Runs `clamscan` over `/home`, `/root`, `/tmp`, `/var/tmp` when the last report is older than 3 days (configurable).
- Parses the scan log and inventories: engine version, signature count, scanned files, infected files, data scanned, last scan time, signature freshness, and detected threats. Infections are reported as an alert on every run.

Only Linux is supported. Windows support is coming soon.

## Installation

```bash
cfbs add clamav
cfbs build
```

## Configuration

Scan intervals, scan targets, and excluded directories can be set interactively with `cfbs input clamav`. Any default can also be overridden via [augments](https://docs.cfengine.com/docs/lts/reference/language-concepts/augments), e.g.:

```json
{
  "variables": {
    "clamav:globals.clamav_version": "1.5.4",
    "clamav:globals.max_age_days": "1",
    "clamav:globals.signature_max_age_days": "1",
    "clamav:globals.scan_target": ["/home", "/srv"],
    "clamav:globals.exclude_dirs": ["/proc", "/sys", "/dev", "/run", "/srv/backup"]
  }
}
```

Entries in `exclude_dirs` are directory paths without a trailing slash. The module anchors each one and passes it to `clamscan --exclude-dir`, which matches it as a path prefix, so `/dev` also covers `/dev/shm`. Setting the list replaces the built-in one (`/proc`, `/sys`, `/dev`, `/run`, `/var/lib/clamav`, `/var/cfengine`), so include any of those you still want.

Trigger actions immediately:

```bash
cf-agent -KI --define clamav:want_scan_now      # force a scan
cf-agent -KI --define clamav:want_freshen_now   # force a signature update
```

## Compliance report

This module contains a ready-made Mission Portal compliance report covering infections, scan recency, and signature freshness - see [compliance-report/README.md](https://github.com/aleksandrychev/cfengine-clamav/blob/main/compliance-report/README.md).

## Notes

- `clamscan` and `freshclam` load the full signature database into memory, ensure at least **~2 GB of available RAM** on scanned hosts. On hosts with less memory, add a swap file with the [manage-swap](https://build.cfengine.com/modules/manage-swap/) module.
- On Debian/Ubuntu, the distro's `clamav-freshclam` daemon locks the signature database while running, which causes the module's `freshclam` runs to fail. Disable it with `systemctl disable --now clamav-freshclam` if CFEngine should manage updates.
