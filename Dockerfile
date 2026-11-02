# Central syslog collector (rsyslog + logrotate) for MikroTik RouterOS
# containers.
#
# SINGLE-ARCH BUILD (arm64 ONLY):
#   arm64 (ARMv8) — RB5009UG+S+ (Cortex-A72). This collector runs only on the
#   main router, so (like ../mikrotik-nginx) there is no arm32 variant.
#
# Two stages:
#   init-build  cross-compiles syslog-init (PID 1, see init/main.go) with Go,
#               same as ../tailscale-mikrotik's ts-init.
#   runtime     Debian + rsyslog + logrotate from the Debian archive.
# The Mac build host is native arm64, so no QEMU is needed (see build.sh).
#
# Build arg (default is arm64 so a bare `docker build` works):
#   RUNTIME_BASE   arm64v8/debian:bookworm-slim
#
# RouterOS LAYER RULE: every layer must change the filesystem. RouterOS stores
# layers by content digest and stacks them as overlayfs lowerdirs, so two
# identical layers (e.g. two empty ones) become a duplicate lowerdir and the
# container fails with "could not mount overlayfs root". Hence --chmod on the
# COPYs (a separate `RUN chmod` can be an empty layer) and the config check
# below writes its result into the image. build.sh rejects images with empty
# or duplicate layers.
ARG RUNTIME_BASE=arm64v8/debian:bookworm-slim

# syslog-init: the container's PID 1. Built on the native build host and
# cross-compiled to arm64.
FROM --platform=$BUILDPLATFORM golang:1.27-alpine AS init-build
WORKDIR /src
COPY init/ .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=arm64 GOTOOLCHAIN=local \
      go build -trimpath -ldflags="-s -w" -o /out/syslog-init . && \
    go version -m /out/syslog-init | grep -E 'GOARCH'

# Bare re-declaration brings the global RUNTIME_BASE into this stage's scope.
ARG RUNTIME_BASE
FROM ${RUNTIME_BASE}

# rsyslog          — the collector (imudp/imtcp + omfile are in the base pkg).
# logrotate        — rotation/retention, driven by syslog.sh (no cron).
# openssh-server   — management access, same pattern as the tor/nginx images.
# tzdata           — so TZ=Europe/London gives local timestamps + rotation day.
# procps           — ps/pgrep for debugging inside the container.
# bash/ca-certificates — scripting + trust store, as in the sibling images.
#
# Like the nginx image we DO NOT install iptables/iproute2: a syslog receiver
# needs no netfilter, so the container also runs unprivileged.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      rsyslog logrotate openssh-server tzdata procps bash ca-certificates && \
    rm -rf /var/lib/apt/lists/* /etc/rsyslog.d/* /etc/logrotate.d/rsyslog && \
    mkdir -p /var/run/sshd /var/spool/rsyslog /var/log/remote

COPY sshd_config /etc/ssh/
COPY --chmod=0644 rsyslog.conf /etc/rsyslog.conf
COPY --chmod=0644 logrotate.conf /etc/logrotate-remote.conf
COPY --chmod=0755 syslog.sh /usr/local/bin/syslog.sh
COPY --from=init-build /out/syslog-init /usr/local/sbin/syslog-init

# Build-time config check: rsyslog and logrotate both parse their configs. The
# result is kept in the image so this layer is never empty.
RUN d=/usr/share/mikrotik-syslog; mkdir -p "$d" && \
    { rsyslogd -N1 -f /etc/rsyslog.conf > "$d/rsyslog-check.txt" 2>&1 \
      || { cat "$d/rsyslog-check.txt"; exit 1; }; } && \
    { logrotate -d -s /tmp/lr.status /etc/logrotate-remote.conf > "$d/logrotate-check.txt" 2>&1 \
      || { cat "$d/logrotate-check.txt"; exit 1; }; } && \
    rm -f /tmp/lr.status && \
    cat "$d/rsyslog-check.txt"

# 5514/udp+tcp syslog (fleet default)   514/udp syslog (standard)   22 SSH
EXPOSE 5514/udp 5514/tcp 514/udp 22

# syslog-init is PID 1: reaps orphaned/zombie processes and forwards the
# RouterOS stop-signal to syslog.sh, which stops rsyslogd gracefully. It must
# install real signal handlers (tini doesn't, so RouterOS SIGKILLs it at once).
# RouterOS `cmd=` overrides CMD only, so syslog-init stays in place as long as
# the container's `entrypoint` property is left empty.
ENTRYPOINT ["/usr/local/sbin/syslog-init", "--"]
CMD ["/usr/local/bin/syslog.sh"]
