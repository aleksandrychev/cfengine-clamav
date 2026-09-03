#!/usr/bin/env bash
# Build the policy sets used by tests/functional.sh.
#
# For each scenario a cfbs policy-set project (masterfiles + this module) is
# created in tests/out/projects/<name> and the built policy set is copied to
# tests/out/policies/<name>. The module is added as a local directory with the
# module's own build steps and input definition, so no git remote is needed.
#
# Environment:
#   CLAMAV_TEST_DIR  Directory the "custom" scenario scans (default: /clamav-test)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"
out="$here/out"
test_dir="${CLAMAV_TEST_DIR:-/clamav-test}"

rm -rf "$out/projects" "$out/policies"
mkdir -p "$out/projects" "$out/policies"

# build_policy <name> <input responses as a JSON object, or "" for no input>
build_policy() {
  local name="$1" responses="$2" project="$out/projects/$1"
  echo "Building policy set '$name' (input: ${responses:-none})"
  mkdir -p "$project/clamav"
  # The module's build steps reference these paths relative to the module root.
  cp -R "$repo/policy" "$repo/cfbs" "$repo/compliance-report" "$project/clamav/"
  # Test-only augments for the Masterfiles Policy Framework (MPF):
  # - the package inventory is slow and unrelated to this module: disable it;
  # - cf-execd must never start agent runs in the background during the test.
  cat > "$project/test-def.json" <<'JSON'
{
  "classes": { "disable_inventory_package_refresh": ["any"] },
  "vars": { "control_executor_schedule": ["!any"] }
}
JSON
  (
    cd "$project"
    cfbs init --non-interactive >/dev/null
    REPO="$repo" RESPONSES="$responses" python3 - <<'PY'
import json, os
with open(os.path.join(os.environ["REPO"], "cfbs.json")) as f:
    module = json.load(f)["provides"]["clamav"]
with open("cfbs.json") as f:
    project = json.load(f)
project["build"].append({
    "name": "./test-def.json",
    "description": "Test-only augments",
    "tags": ["local"],
    "steps": ["json ./test-def.json def.json"],
    "added_by": "cfbs add",
})
project["build"].append({
    "name": "./clamav/",
    "description": module["description"],
    "tags": ["local"],
    "steps": module["steps"],
    "input": module["input"],
    "added_by": "cfbs add",
})
with open("cfbs.json", "w") as f:
    json.dump(project, f, indent=2)
# Mimic `cfbs input`: the module's input definition with the answers filled in.
responses = json.loads(os.environ["RESPONSES"] or "{}")
if responses:
    data = []
    for element in module["input"]:
        element = dict(element)
        if element["variable"] in responses:
            element["response"] = responses[element["variable"]]
        data.append(element)
    with open("clamav/input.json", "w") as f:
        json.dump(data, f, indent=2)
PY
    cfbs build >/dev/null
  )
  cp -R "$project/out/masterfiles" "$out/policies/$name"
}

# Short intervals, a dedicated scan directory and one excluded subdirectory.
custom_input="$(printf '{"max_age_days": "1", "signature_max_age_days": "1", "scan_target": ["%s/scan"], "exclude_dirs": ["%s/scan/skip"]}' "$test_dir" "$test_dir")"
build_policy custom "$custom_input"
build_policy defaults ""   # no input at all: built-in defaults

echo "Policy sets built in $out/policies"
