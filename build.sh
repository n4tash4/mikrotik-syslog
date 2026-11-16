#!/usr/bin/env sh
VERSION=0.1.0
set -eu

EMPTY_LAYER_SHA256=5f70bf18a086007016e948b04aed3b82103a36bea41755b6cddfaf10ace3c6ef

build_arch() {
    _name="$1"
    _platform="$2"
    _runtime_base="$3"
    _out="syslog-${_name}.tar"
    _tag="syslog-mikrotik:${VERSION}-${_name}"

    echo ">>> Building ${_name}  (${_platform}, base ${_runtime_base}) -> ${_out}"
    rm -f "${_out}"

    set -- --pull
    if [ "${NO_CACHE:-}" = "1" ]; then set -- "$@" --no-cache; fi
    docker buildx build "$@" \
      --build-arg RUNTIME_BASE="${_runtime_base}" \
      --platform "${_platform}" \
      --load -t "${_tag}" .

    _layers=$(docker image inspect \
      --format '{{range .RootFS.Layers}}{{println .}}{{end}}' "${_tag}" | sed '/^$/d')
    _dups=$(printf '%s\n' "$_layers" | sort | uniq -d)
    if [ -n "$_dups" ]; then
        echo "ERROR: image has duplicate layers (RouterOS overlayfs will fail):" >&2
        printf '  %s\n' $_dups >&2
        exit 1
    fi
    if printf '%s\n' "$_layers" | grep -q "${EMPTY_LAYER_SHA256}"; then
        echo "ERROR: image has an empty layer (a RUN/COPY that changed nothing); every layer must change the filesystem or RouterOS fails to mount overlayfs." >&2
        exit 1
    fi
    echo ">>> Layer check OK ($(printf '%s\n' "$_layers" | wc -l | tr -d ' ') layers, no duplicates/empties)"

    skopeo copy \
      "docker-daemon:${_tag}" \
      "docker-archive:${_out}"
    echo ">>> Done: ${_out}"
}

build_arch arm64 "linux/arm64" "arm64v8/debian:bookworm-slim"

echo ">>> Build complete."
ls -lh syslog-*.tar 2>/dev/null || true
