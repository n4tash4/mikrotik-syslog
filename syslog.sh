#!/bin/bash
# mikrotik-syslog container entrypoint: central syslog collector for the
# RouterOS fleet, running as a container on the main router.
#
# Process model
# -------------
# PID 1 is syslog-init (Dockerfile ENTRYPOINT, source in init/): it reaps
# orphaned/zombie processes (logrotate's gzip/postrotate children, sshd
# sessions) and forwards the RouterOS stop-signal (SIGTERM by default) to this
# script. RouterOS only delivers the stop-signal if PID 1 has a handler
# installed for it, which is why this isn't tini.
#
# This script supervises three children and the container's lifetime follows
# rsyslogd: if rsyslogd exits, everything is stopped and the script exits with
# rsyslogd's status (pair with RouterOS restart-policy=on-failure).
# On SIGTERM/SIGINT rsyslogd is stopped gracefully so it flushes its queues
# to disk instead of losing buffered lines.
#
# Long-running steps run in the background + `wait`, because bash only runs a
# trap after the current foreground command returns; `wait` returns as soon
# as a trapped signal arrives.
#
# Nothing high-volume is written to stdout: the container runs with
# logging=yes, so stdout lands in the router's own log, which is forwarded back
# here. Only lifecycle messages are echoed.
#
# Env contract
# ------------
#   PASSWORD                    root password for management SSH     [optional]
#                               (unset -> no password login; use
#                               /container/shell from the router)
#   LOGROTATE_INTERVAL_SECONDS  how often logrotate runs (default 900). Its
#                               maxsize check only happens on a run, so this
#                               bounds how far past 32M a file can grow.
#   TZ                          timezone for timestamps and rotation
#                               (default Europe/London, same as the fleet)

LOGROTATE_INTERVAL_SECONDS="${LOGROTATE_INTERVAL_SECONDS:-900}"
export TZ="${TZ:-Europe/London}"

LOG_DIR=/var/log/remote
STATE_DIR="${LOG_DIR}/.state"

RSYSLOGD_PID=""
SSHD_PID=""
ROTATE_PID=""

shutdown() {
  trap - TERM INT
  echo "syslog.sh: stop signal received; shutting down"
  [[ -n "${SSHD_PID}" ]]   && kill -TERM "${SSHD_PID}"   2>/dev/null
  [[ -n "${ROTATE_PID}" ]] && kill -TERM "${ROTATE_PID}" 2>/dev/null
  if [[ -n "${RSYSLOGD_PID}" ]] && kill -0 "${RSYSLOGD_PID}" 2>/dev/null; then
    kill -TERM "${RSYSLOGD_PID}" 2>/dev/null
    wait "${RSYSLOGD_PID}"
  fi
  exit 0
}
trap shutdown TERM INT

fatal() { echo "syslog.sh FATAL: $1" >&2; exit 1; }

case "${LOGROTATE_INTERVAL_SECONDS}" in
  ''|*[!0-9]*) fatal "LOGROTATE_INTERVAL_SECONDS must be a positive integer (got '${LOGROTATE_INTERVAL_SECONDS}')." ;;
esac
[ "${LOGROTATE_INTERVAL_SECONDS}" -gt 0 ] || fatal "LOGROTATE_INTERVAL_SECONDS must be > 0."

# ---------------------------------------------------------------------------
# (1) Directories. LOG_DIR is the persistent RouterOS mount; .state holds the
# logrotate state file so "daily" survives restarts. Not matched by the
# logrotate glob (*.log), so it is never rotated itself.
# ---------------------------------------------------------------------------
mkdir -p "${LOG_DIR}" "${STATE_DIR}" /var/spool/rsyslog /var/run/sshd
chmod 0750 "${LOG_DIR}"
rm -f /run/rsyslogd.pid

# ---------------------------------------------------------------------------
# (2) SSH management server prep (same pattern as the tor/nginx containers).
# Host keys are generated at first start, not build time — per-container keys
# are better practice.
# ---------------------------------------------------------------------------
if [ ! -f /etc/ssh/ssh_host_ed25519_key ]; then
  ssh-keygen -A
fi
if [ -n "${PASSWORD:-}" ]; then
  echo "root:${PASSWORD}" | chpasswd
fi

# ---------------------------------------------------------------------------
# (3) Validate the config before starting, so a bad edit fails loudly in the
# RouterOS container log instead of a silent collector that drops everything.
# ---------------------------------------------------------------------------
rsyslogd -N1 -f /etc/rsyslog.conf >/dev/null 2>&1 || {
  rsyslogd -N1 -f /etc/rsyslog.conf
  fatal "rsyslog.conf failed validation."
}

# ---------------------------------------------------------------------------
# (4) rsyslogd in the foreground (-n) as our child, so we can wait on it.
# -iNONE would skip the pidfile, but logrotate's postrotate HUPs via it.
# ---------------------------------------------------------------------------
rsyslogd -n -f /etc/rsyslog.conf -i /run/rsyslogd.pid &
RSYSLOGD_PID=$!
echo "syslog.sh: rsyslogd started (pid ${RSYSLOGD_PID}); writing to ${LOG_DIR}"

# ---------------------------------------------------------------------------
# (5) logrotate loop. Runs once shortly after start (catches up on a missed
# daily rotation after downtime), then every LOGROTATE_INTERVAL_SECONDS.
# Errors go to a file in the log dir rather than stdout (see header).
# ---------------------------------------------------------------------------
(
  sp=""
  trap '[[ -n "$sp" ]] && kill -TERM "$sp" 2>/dev/null; exit 0' TERM INT
  sleep 30 & sp=$!; wait "$sp"
  while :; do
    logrotate -s "${STATE_DIR}/logrotate.status" /etc/logrotate-remote.conf \
      >"${STATE_DIR}/logrotate.last" 2>&1 \
      || echo "syslog.sh: logrotate failed ($?), see ${STATE_DIR}/logrotate.last" >&2
    sleep "${LOGROTATE_INTERVAL_SECONDS}" & sp=$!; wait "$sp"
  done
) &
ROTATE_PID=$!
echo "syslog.sh: logrotate every ${LOGROTATE_INTERVAL_SECONDS}s (daily or >32M, keep 7 / 14d)"

# ---------------------------------------------------------------------------
# (6) SSH.
# ---------------------------------------------------------------------------
/usr/sbin/sshd -D &
SSHD_PID=$!

# Container lifetime follows rsyslogd. `wait` is interrupted by the trap on
# SIGTERM/SIGINT (shutdown() then exits), so loop until rsyslogd is gone.
while kill -0 "${RSYSLOGD_PID}" 2>/dev/null; do
  wait "${RSYSLOGD_PID}"; rc=$?
done
echo "syslog.sh: rsyslogd exited (${rc:-?}); stopping container" >&2
[[ -n "${SSHD_PID}" ]]   && kill -TERM "${SSHD_PID}"   2>/dev/null
[[ -n "${ROTATE_PID}" ]] && kill -TERM "${ROTATE_PID}" 2>/dev/null
exit "${rc:-1}"
