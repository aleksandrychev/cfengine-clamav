#!/usr/bin/env bash
# Run the functional test locally in Docker.
#
# Builds the policy sets with cfbs, builds an Ubuntu image with CFEngine
# installed via `cf-remote install --clients localhost`, and runs
# tests/functional.sh as root in a container. The ClamAV package and signature
# database are downloaded inside the container, so this needs network access
# and takes a few minutes. Give the Docker VM at least 3 GB of memory: clamscan
# loads the whole signature database.
#
# Requirements: cfbs, docker.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
out="$here/out"
image="cfengine-clamav-test"
export CLAMAV_TEST_DIR="${CLAMAV_TEST_DIR:-/clamav-test}"

bash "$here/build-policies.sh"

mkdir -p "$out/docker"
cat > "$out/docker/Dockerfile" <<'DOCKERFILE'
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
# sudo is needed by cf-remote even when running as root; python3 must be present
# before CFEngine is installed so its package modules can use it; curl is what
# the module downloads the ClamAV package with. The apt lists are kept so that
# apt-get can resolve the package's dependencies during the test.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl procps sudo python3 python3-pip
RUN pip3 install --break-system-packages --no-cache-dir cf-remote
RUN cf-remote install --clients localhost --edition community
ENV PATH="/var/cfengine/bin:${PATH}"
DOCKERFILE
docker build -q -t "$image" "$out/docker" >/dev/null

docker run --rm \
  -v "$out/policies:/policies:ro" \
  -v "$here/functional.sh:/functional.sh:ro" \
  -e CLAMAV_TEST_DIR -e POLICIES=/policies \
  "$image" bash /functional.sh
