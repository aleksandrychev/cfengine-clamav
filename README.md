# cfengine-clamav

CFEngine build module that installs [ClamAV](https://www.clamav.net/) from upstream packages, keeps its signatures fresh, runs periodic scans, and reports the results as CFEngine Enterprise inventory.

![Mission Portal inventory](https://raw.githubusercontent.com/aleksandrychev/cfengine-clamav/main/inventory.png)

## What it does

- Installs the upstream ClamAV `.deb`/`.rpm` from clamav.net (Debian/Ubuntu and RHEL-family, x86_64/aarch64) and creates the `clamav` user.
- Runs `freshclam` when signatures are older than 48 hours (configurable).
- Runs `clamscan` over `/home`, `/root`, `/tmp`, `/var/tmp` when the last report is older than 3 days (configurable).
- Parses the scan log and inventories: engine version, signature count, scanned files, infected files, data scanned, last scan time, signature freshness, and detected threats. Infections are reported as an alert on every run.

Only Linux is supported. Windows support is coming soon.

## Installation

```bash
cfbs add clamav
cfbs build
```

## Configuration

Override defaults via [augments](https://docs.cfengine.com/docs/lts/reference/language-concepts/augments), e.g.:

```json
{
  "variables": {
    "clamav:globals.clamav_version": "1.5.4",
    "clamav:globals.max_age_days": "1",
    "clamav:globals.signature_max_age_hours": "24",
    "clamav:globals.scan_target_linux": ["/home", "/srv"]
  }
}
```

Trigger actions immediately:

```bash
cf-agent -KI --define clamav:want_scan_now      # force a scan
cf-agent -KI --define clamav:want_freshen_now   # force a signature update
```

## Compliance report

This module contains a ready-made Mission Portal compliance report covering infections, scan recency, and signature freshness - see [compliance-report/README.md](https://github.com/aleksandrychev/cfengine-clamav/blob/main/compliance-report/README.md).

## Notes

- `clamscan` and `freshclam` load the full signature database into memory, ensure at least **~2 GB of available RAM** on scanned hosts.
- On Debian/Ubuntu, the distro's `clamav-freshclam` daemon locks the signature database while running, which causes the module's `freshclam` runs to fail. Disable it with `systemctl disable --now clamav-freshclam` if CFEngine should manage updates.
