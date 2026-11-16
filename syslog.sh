#!/bin/bash
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

mkdir -p "${LOG_DIR}" "${STATE_DIR}" /var/spool/rsyslog /var/run/sshd
chmod 0750 "${LOG_DIR}"
rm -f /run/rsyslogd.pid

HOSTKEY_DIR=/etc/ssh/host-keys
mkdir -p "${HOSTKEY_DIR}"
chown root:root "${HOSTKEY_DIR}"
chmod 700 "${HOSTKEY_DIR}"
for t in ed25519 rsa; do
  k="${HOSTKEY_DIR}/ssh_host_${t}_key"
  if [ ! -s "${k}" ]; then
    rm -f "${k}" "${k}.pub"
    ssh-keygen -q -t "${t}" -N '' -f "${k}"
  fi
  chown root:root "${k}" "${k}.pub"
  chmod 600 "${k}"
  chmod 644 "${k}.pub"
done
chown root:root /root
chmod 700 /root
mkdir -p /root/.ssh
chown root:root /root/.ssh
chmod 700 /root/.ssh
if [ -n "${AUTHORIZED_KEYS:-}" ]; then
  printf '%s\n' "${AUTHORIZED_KEYS}" > /root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys
else
  rm -f /root/.ssh/authorized_keys
  echo "WARNING: AUTHORIZED_KEYS not set; SSH login is disabled." >&2
fi

rsyslogd -N1 -f /etc/rsyslog.conf >/dev/null 2>&1 || {
  rsyslogd -N1 -f /etc/rsyslog.conf
  fatal "rsyslog.conf failed validation."
}

rsyslogd -n -f /etc/rsyslog.conf -i /run/rsyslogd.pid &
RSYSLOGD_PID=$!
echo "syslog.sh: rsyslogd started (pid ${RSYSLOGD_PID}); writing to ${LOG_DIR}"

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

/usr/sbin/sshd -D &
SSHD_PID=$!

while kill -0 "${RSYSLOGD_PID}" 2>/dev/null; do
  wait "${RSYSLOGD_PID}"; rc=$?
done
echo "syslog.sh: rsyslogd exited (${rc:-?}); stopping container" >&2
[[ -n "${SSHD_PID}" ]]   && kill -TERM "${SSHD_PID}"   2>/dev/null
[[ -n "${ROTATE_PID}" ]] && kill -TERM "${ROTATE_PID}" 2>/dev/null
exit "${rc:-1}"
