#!/usr/bin/env bash
# Functional test of the clamav module.
#
# Runs cf-agent with the policy sets built by tests/build-policies.sh and checks
# the resulting state. Must run as root on a Debian/Ubuntu host with CFEngine
# installed (a GitHub Actions runner, or the container started by
# tests/run-locally.sh). Needs network access to clamav.net for the package and
# to database.clamav.net for the signatures. ClamAV is left installed under
# /usr/local afterwards; only the test directory is removed.
#
# Environment:
#   POLICIES         Directory with the built policy sets (default: tests/out/policies)
#   CLAMAV_TEST_DIR  Directory scanned by the "custom" policy set (default: /clamav-test)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
policies="${POLICIES:-$here/out/policies}"
test_dir="${CLAMAV_TEST_DIR:-/clamav-test}"
export PATH="/var/cfengine/bin:$PATH"

clamscan=/usr/local/bin/clamscan
signature_dir=/usr/local/share/clamav
report=/var/log/clamav/clamav-scan.log
marker=/var/log/clamav/.cfengine_last_freshen
log=/tmp/agent.log

[ "$(id -u)" = "0" ] || { echo "must run as root" >&2; exit 1; }
command -v cf-agent >/dev/null || { echo "cf-agent not found" >&2; exit 1; }
[ -d "$policies/custom" ] || { echo "policy sets not found in $policies, run tests/build-policies.sh" >&2; exit 1; }

cleanup() { rm -rf "$test_dir"; }
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  echo "--- agent log (tail) ---" >&2
  tail -n 40 "$log" >&2 2>/dev/null || true
  echo "--- freshclam log (tail) ---" >&2
  tail -n 20 /var/log/clamav/freshclam.log >&2 2>/dev/null || true
  exit 1
}

use_policy() {
  rm -rf /var/cfengine/inputs
  cp -R "$policies/$1" /var/cfengine/inputs
}
# run_agent [extra cf-agent args]
run_agent() {
  cf-agent -KI -f /var/cfengine/inputs/promises.cf "$@" > "$log" 2>&1 || true
  grep -E "clamav|error" "$log" || true
  if grep -q "error:" "$log"; then fail "agent run had errors"; fi
}
# show_vars <variable name regex>: evaluated variables after a full agent run
show_vars() {
  cf-agent -KI -f /var/cfengine/inputs/promises.cf --show-evaluated-vars="$1" 2>&1
}
mtime() { stat -c %Y "$1"; }
age_seconds() { echo $(( $(date +%s) - $(mtime "$1") )); }

# No background agent runs during the test: stop CFEngine daemons if the
# package started them (the test policy sets also give cf-execd an empty schedule).
systemctl stop cfengine3 2>/dev/null || true
pkill -x cf-execd 2>/dev/null || true
pkill -x cf-serverd 2>/dev/null || true
pkill -x cf-monitord 2>/dev/null || true

# Test tree: one EICAR test file that must be found, one in an excluded
# subdirectory that must not. The EICAR string is assembled from two halves so
# that this script itself does not match antivirus signatures.
# shellcheck disable=SC2016  # the $ signs are part of the EICAR string
eicar_a='X5O!P%@AP[4\PZX54(P^)7CC)7}$EICAR-STANDARD-'
# shellcheck disable=SC2016
eicar_b='ANTIVIRUS-TEST-FILE!$H+H*'
rm -rf "$test_dir"
mkdir -p "$test_dir/scan/skip"
printf '%s%s' "$eicar_a" "$eicar_b" > "$test_dir/scan/eicar.txt"
printf '%s%s' "$eicar_a" "$eicar_b" > "$test_dir/scan/skip/eicar.txt"
echo "nothing to see here" > "$test_dir/scan/clean.txt"

# Start from a clean module state, whatever the host has.
rm -f "$report" "$marker"

# Emulate what bootstrapping does for the package modules: the MPF update
# policy creates the Python symlink and renders modules/packages/* into
# /var/cfengine/modules. Only these two bundles are run, so no daemons start.
# The copy-from-policy-server promises fail on an unbootstrapped host, which
# is expected and ignored here.
use_policy custom
cf-agent -KI -f /var/cfengine/inputs/update.cf -b update_def,cfe_internal_update_policy > /tmp/update.log 2>&1 || true
[ -e /var/cfengine/bin/cfengine-selected-python ] || { cat /tmp/update.log; fail "update policy did not create the python symlink"; }
[ -x /var/cfengine/modules/packages/apt_get ] || { cat /tmp/update.log; fail "update policy did not install the apt_get package module"; }

echo "### 1. fresh host: install ClamAV, write freshclam config, update signatures, scan"
run_agent
[ -x "$clamscan" ] || fail "clamscan not installed at $clamscan"
"$clamscan" --version | grep -q "ClamAV 1.5.4" || fail "unexpected version: $("$clamscan" --version)"
id clamav >/dev/null 2>&1 || fail "clamav user not created"
grep -q "^DatabaseDirectory $signature_dir$" /usr/local/etc/freshclam.conf || fail "freshclam.conf not written"
[ -f "$marker" ] || fail "freshen marker not created"
[ -f "$signature_dir/daily.cld" ] || [ -f "$signature_dir/daily.cvd" ] || fail "signatures not downloaded"
[ -f "$report" ] || fail "scan report not written"
grep -q "^Infected files: 1$" "$report" || fail "expected exactly 1 infected file, report says: $(grep 'Infected files' "$report" || true)"
grep -q "^$test_dir/scan/eicar.txt: .* FOUND$" "$report" || fail "EICAR test file not detected"
grep -q "$test_dir/scan/skip/" "$report" && fail "excluded directory was scanned"
grep -q "ALERT .* 1 infected file" "$log" || fail "infection alert not reported"
echo "OK"

echo "### 2. second run: report and signatures are fresh, nothing re-run"
report_before="$(mtime "$report")"
marker_before="$(mtime "$marker")"
sleep 1
run_agent
[ "$(mtime "$report")" = "$report_before" ] || fail "scan re-run although the report is fresh"
[ "$(mtime "$marker")" = "$marker_before" ] || fail "freshclam re-run although the marker is fresh"
echo "OK"

echo "### 3. clamav:want_scan_now forces a scan"
sleep 1
run_agent --define clamav:want_scan_now
[ "$(mtime "$report")" -gt "$report_before" ] || fail "forced scan did not run"
echo "OK"

echo "### 4. report older than max_age_days (1) triggers a scan"
touch -d '2 days ago' "$report"
run_agent
[ "$(age_seconds "$report")" -lt 3600 ] || fail "stale report did not trigger a scan"
echo "OK"

echo "### 5. marker older than signature_max_age_days (1) triggers freshclam"
touch -d '2 days ago' "$marker"
run_agent
[ "$(age_seconds "$marker")" -lt 3600 ] || fail "stale marker did not trigger freshclam"
echo "OK"

echo "### 6. input values reach the policy, exclusions are anchored, days become hours"
show_vars 'clamav:globals' > /tmp/vars.log
grep -qE "clamav:globals\.scan_target_str[[:space:]]+$test_dir/scan([[:space:]]|$)" /tmp/vars.log || fail "scan_target input not applied"
grep -qE "clamav:globals\.exclude_args[[:space:]]+--exclude-dir=\^$test_dir/scan/skip([[:space:]]|$)" /tmp/vars.log || fail "exclude_dirs input not applied or not anchored"
grep -qE "clamav:globals\.max_age_days[[:space:]]+1([[:space:]]|$)" /tmp/vars.log || fail "max_age_days input not applied"
grep -qE "clamav:globals\.signature_max_age_days[[:space:]]+1([[:space:]]|$)" /tmp/vars.log || fail "signature_max_age_days input not applied"
show_vars 'clamav:freshen_linux' | grep -qE "max_age_hours[[:space:]]+24([[:space:]]|$)" || fail "signature_max_age_days not converted to 24 hours"
echo "OK"

echo "### 7. inventory variables"
show_vars 'clamav:inventory_linux' > /tmp/inventory.log
grep -qE "infected_files[[:space:]]+1[[:space:]].*attribute_name=ClamAV Infected files" /tmp/inventory.log || fail "infected_files not inventoried"
grep -qE "engine_version[[:space:]]+1\.5\.4[[:space:]].*attribute_name=ClamAV Engine version" /tmp/inventory.log || fail "engine_version not inventoried"
grep -qE "infections[[:space:]].*$test_dir/scan/eicar\.txt: .* FOUND" /tmp/inventory.log || fail "detected threat not inventoried"
grep -qE "signatures_last_updated[[:space:]]+[0-9]{4}-[0-9]{2}-[0-9]{2} " /tmp/inventory.log || fail "signature freshness not inventoried"
echo "OK"

echo "### 8. no input at all: built-in defaults are used"
use_policy defaults
# The report and marker are fresh, so this run neither scans nor updates.
show_vars 'clamav:globals' > /tmp/defaults.log
grep -qE "clamav:globals\.scan_target_str[[:space:]]+/home /root /tmp /var/tmp([[:space:]]|$)" /tmp/defaults.log || fail "default scan targets wrong"
grep -qE "clamav:globals\.exclude_args[[:space:]]+--exclude-dir=\^/proc .*--exclude-dir=\^/var/cfengine([[:space:]]|$)" /tmp/defaults.log || fail "default exclusions wrong"
grep -qE "clamav:globals\.max_age_days[[:space:]]+3([[:space:]]|$)" /tmp/defaults.log || fail "default max_age_days not 3"
grep -qE "clamav:globals\.signature_max_age_days[[:space:]]+2([[:space:]]|$)" /tmp/defaults.log || fail "default signature_max_age_days not 2"
echo "OK"

echo "ALL TESTS PASSED"
