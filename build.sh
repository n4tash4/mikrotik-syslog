#!/usr/bin/env sh
# Build the central syslog collector (rsyslog + logrotate) container for
# MikroTik RouterOS, producing a single container-archive tar.
#
# Mirrors ../mikrotik-nginx/build.sh (ARM64 ONLY), plus the RouterOS layer
# check from ../tailscale-mikrotik/build.sh:
#
#   syslog-arm64.tar  linux/arm64  ARMv8  -> RB5009 (Cortex-A72) main router
#
# arm32 is intentionally not built: the collector runs only on the router.
#
# The Mac build host is native arm64, so no QEMU is needed. On a non-arm64
# host, register QEMU once first:
#   docker run --privileged --rm tonistiigi/binfmt --install all
#
# Requires Docker Buildx and skopeo.
#
# Usage:
#   ./build.sh              # -> syslog-arm64.tar (layer cache on, --pull)
#   NO_CACHE=1 ./build.sh   # full clean rebuild
VERSION=0.1.0
set -eu

# --pull re-checks the base images every build, so a new debian:bookworm-slim
# (security updates) or golang image invalidates the cache below it instead of
# a stale apt layer living forever.
_nocache=""
if [ "${NO_CACHE:-}" = "1" ]; then _nocache="--no-cache"; fi

build_arch() {
    _name="$1"
    _platform="$2"
    _runtime_base="$3"
    _out="syslog-${_name}.tar"
    _tag="syslog-mikrotik:${VERSION}-${_name}"

    echo ">>> Building ${_name}  (${_platform}, base ${_runtime_base}) -> ${_out}"
    rm -f "${_out}"

    # shellcheck disable=SC2086
    docker buildx build \
      --pull ${_nocache} \
      --build-arg RUNTIME_BASE="${_runtime_base}" \
      --platform "${_platform}" \
      --load -t "${_tag}" .

    # RouterOS can't run images with an empty layer twice / any duplicate layer
    # (duplicate overlayfs lowerdir -> "could not mount overlayfs root").
    # Reject them here rather than discovering it on the router.
    _layers=$(docker image inspect \
      --format '{{range .RootFS.Layers}}{{println .}}{{end}}' "${_tag}" | sed '/^$/d')
    _dups=$(printf '%s\n' "$_layers" | sort | uniq -d)
    if [ -n "$_dups" ]; then
        echo "ERROR: image has duplicate layers (RouterOS overlayfs will fail):" >&2
        printf '  %s\n' $_dups >&2
        exit 1
    fi
    # sha256 of an empty layer tar: flag it so it can't creep in.
    if printf '%s\n' "$_layers" | grep -q '5f70bf18a086007016e948b04aed3b82103a36bea41755b6cddfaf10ace3c6ef'; then
        echo "ERROR: image has an empty layer (a RUN/COPY that changed nothing)." >&2
        exit 1
    fi
    echo ">>> Layer check OK ($(printf '%s\n' "$_layers" | wc -l | tr -d ' ') layers, no duplicates/empties)"

    skopeo copy \
      "docker-daemon:${_tag}" \
      "docker-archive:${_out}"
    echo ">>> Done: ${_out}"
}

# Single arch (arm64) — no arch matrix to iterate.
build_arch arm64 "linux/arm64" "arm64v8/debian:bookworm-slim"

echo ">>> Build complete."
ls -lh syslog-*.tar 2>/dev/null || true
