# Build & verification evidence

Captured 2026-11-02 on the arm64 Mac build host (native arm64, no QEMU) and
the live router (RB5009, RouterOS 7.25).

## Lint

- `bash -n syslog.sh`, `sh -n build.sh`: exit 0

## Image build

- `./build.sh` succeeded and produced `syslog-arm64.tar` (127M), tag
  `syslog-mikrotik:0.1.0-arm64`, base `arm64v8/debian:bookworm-slim`,
  rsyslog 8.2302.0.
- Layer check OK: 8 layers, no duplicates/empties.
- The build-time config check caught a real bug on the first build: a bare
  `$` inside a double-quoted RainerScript regex is a parse error. It was fixed
  by single-quoting the regexes.

## Local runtime test (`docker run`)

- PID 1 is `syslog-init`. `/proc/1/status` `SigCgt: fffffffd7fc1feff` has
  bit 15 set, so SIGTERM is caught and RouterOS will not SIGKILL on stop.
- Process tree: `syslog-init -> syslog.sh -> {rsyslogd, logrotate loop, sshd}`.
- Ingest on UDP 5514, UDP 514 and TCP 5514 all landed in `<host>.log` and
  `all.log`.
- Size rotation: appended 34M to `all.log` with `LOGROTATE_INTERVAL_SECONDS=5`.
  It was rotated to `all.log-20261102-182041.gz` (172K), rsyslogd logged
  "rsyslogd was HUPed", and the next message went into a freshly created
  `all.log`. `/proc/<rsyslogd>/fd` showed the new file open.
- Graceful stop: `docker stop` took under 1s, exit code 0, and rsyslogd logged
  "exiting on signal 15".

## Router deploy

- `secrets.local.rsc` and `01-router-syslog.rsc` were imported. The secrets
  file was deleted from the router immediately after import.
- Container `syslog-router` is running on `veth-syslog` 192.168.102.3; the
  router log shows `started /usr/local/sbin/syslog-init -- /usr/local/bin/syslog.sh`.
- Forward chain order: the `syslog:` accepts sit at positions 23/24, directly
  before the `ANYCAST-FW: TODO-DROP` catch-all at 25.
- Fleet (`../mikrotik`, `--tags syslog`) was applied to router, coresw-1,
  coresw2-a, distsw, srvsw1, srvsw3, haxs and hap1-5. A `:log info` on each
  one appeared in `all.log` under its own host name (12/12).

## Not done

- ap1, ap2, ap3, srvsw2, coresw2-b and srvsw4 were not reachable from the
  build host (API/SSH timed out; ap1 doesn't answer ping even from the router),
  so they have not received the syslog config. They pick it up on the next
  `make deploy` / `--tags syslog` run once reachable.
- Nothing committed.
