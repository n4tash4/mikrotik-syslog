ARG RUNTIME_BASE=arm64v8/debian:bookworm-slim

FROM --platform=$BUILDPLATFORM golang:1.27-alpine AS init-build
WORKDIR /src
COPY init/ .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=arm64 GOTOOLCHAIN=local \
      go build -trimpath -ldflags="-s -w" -o /out/syslog-init . && \
    go version -m /out/syslog-init | grep -E 'GOARCH'

ARG RUNTIME_BASE
FROM ${RUNTIME_BASE}

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      rsyslog logrotate openssh-server tzdata procps bash ca-certificates && \
    rm -rf /var/lib/apt/lists/* \
    /etc/rsyslog.d/* /etc/logrotate.d/rsyslog && \
    rm -f /etc/ssh/ssh_host_* && \
    mkdir -p /var/run/sshd /var/spool/rsyslog /var/log/remote

COPY sshd_config /etc/ssh/
COPY --chmod=0644 rsyslog.conf /etc/rsyslog.conf
COPY --chmod=0644 logrotate.conf /etc/logrotate-remote.conf
COPY --chmod=0755 syslog.sh /usr/local/bin/syslog.sh
COPY --from=init-build /out/syslog-init /usr/local/sbin/syslog-init

RUN d=/usr/share/mikrotik-syslog; mkdir -p "$d" && \
    { rsyslogd -N1 -f /etc/rsyslog.conf > "$d/rsyslog-check.txt" 2>&1 \
      || { cat "$d/rsyslog-check.txt"; exit 1; }; } && \
    { logrotate -d -s /tmp/lr.status /etc/logrotate-remote.conf > "$d/logrotate-check.txt" 2>&1 \
      || { cat "$d/logrotate-check.txt"; exit 1; }; } && \
    rm -f /tmp/lr.status && \
    cat "$d/rsyslog-check.txt"

EXPOSE 5514/udp 5514/tcp 514/udp 22

ENTRYPOINT ["/usr/local/sbin/syslog-init", "--"]
CMD ["/usr/local/bin/syslog.sh"]
