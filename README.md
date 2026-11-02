# Central syslog collector for MikroTik Container (rsyslog + logrotate)

Build and configuration to run [rsyslog](https://www.rsyslog.com/) with
[logrotate](https://github.com/logrotate/logrotate) inside a
[MikroTik Container](https://help.mikrotik.com/docs/display/ROS/Container) on
the main router, as the **central syslog receiver** for the whole RouterOS
fleet (router, core/dist/server switches, hAP APs).

RouterOS can only *send* remote syslog, not receive it, so this container is
the receiver. It writes one file per device plus a combined `all.log`, and
rotates/trims them itself. The log directory is a RouterOS mount, so the files
are also visible from the router's own `/file` menu.

Structured to match the sibling [`mikrotik-nginx`](../mikrotik-nginx),
[`tor-mikrotik`](../tor-mikrotik) and
[`tailscale-mikrotik`](../tailscale-mikrotik) projects: same management-SSH
pattern, env-driven container, build model (buildx + skopeo), and the same
custom PID 1 as tailscale-mikrotik (see [Process model](#process-model)). The
RouterOS-side plumbing (veth, container, firewall) lives in [`rsc/`](rsc); the
fleet-side "send logs here" config lives in the [`../mikrotik`](../mikrotik)
Ansible inventory.

## Requirements

RouterOS v7.22+ with the Container package and container `device-mode`
enabled, and the router's ext4 USB disk (fs-label `router1-containers`) pinned
to the fixed mount-point `/storage`. That disk setup is shared with the nginx
container; see the "Why the disk is pinned to `/storage`" note in
[`../mikrotik-nginx/README.md`](../mikrotik-nginx/README.md).

Build host: Docker Buildx and skopeo. The Mac build host is native arm64, so no
QEMU is needed.

## Build

```sh
./build.sh              # -> syslog-arm64.tar  (layer cache on, --pull)
NO_CACHE=1 ./build.sh   # full clean rebuild
```

arm64 only (RB5009). The build:

- cross-compiles `syslog-init` (the PID 1) in a Go stage,
- installs rsyslog/logrotate from the Debian bookworm archive,
- validates `rsyslog.conf` (`rsyslogd -N1`) and `logrotate.conf`
  (`logrotate -d`) at build time, failing the build on a bad config,
- rejects images with **empty or duplicate layers**, which RouterOS can't
  mount ("could not mount overlayfs root"). That's why the Dockerfile uses
  `COPY --chmod` instead of separate `RUN chmod` steps.

## Process model

```
syslog-init (PID 1)  ->  syslog.sh  ->  rsyslogd -n
                                    ->  logrotate loop (every 15 min)
                                    ->  sshd -D
```

- **`syslog-init`** ([`init/main.go`](init/main.go), ported from
  tailscale-mikrotik's `ts-init`) reaps zombies and forwards signals. It is not
  tini on purpose: RouterOS only sends the stop-signal to PID 1 if PID 1 has a
  real handler installed (`SigCgt`), otherwise it logs "signal 15 not caught,
  kill immediately" and SIGKILLs. tini/dumb-init block-and-wait instead, so
  they always get SIGKILLed.
- **`syslog.sh`** supervises the three children. On SIGTERM it stops rsyslogd
  gracefully, so queued lines are flushed. If rsyslogd dies, the script exits
  non-zero and RouterOS restarts the container (`restart-policy=on-failure`).
- Nothing high-volume goes to stdout. The container runs with `logging=yes`,
  and the router's log is itself forwarded here, so chatty stdout would loop.

## Log layout and rotation

Inside the container `/var/log/remote`, on the router `storage/syslog/log`:

| File | Contents |
|---|---|
| `<host>.log` | one per device, e.g. `hap2.log`, `router.log` |
| `all.log` | every device interleaved, for cross-device correlation |
| `_rsyslogd.log` | rsyslogd's own start/HUP/error messages |
| `*.log-YYYYMMDD-HHMMSS.gz` | rotated copies |
| `.state/` | logrotate state + output of the last run |

Line format:

```
2026-11-02T19:50:15.662891+00:00 hap1 wireless,info 24:B2:...@cap-wifi6 disconnected, connection lost, ...
```

- The timestamp is the **receive time** on the router clock, not the device's.
  A freshly booted AP logs with a wrong clock until NTP syncs, and correlating
  devices needs one clock.
- The host name comes from **reverse DNS** of the sender IP. The router's
  static `*.dids.atasha.net` records give automatic PTRs (`192.168.100.45` ->
  `hap1`). A sender with no PTR gets a file named by its IP.

Rotation (`logrotate.conf`, run every `LOGROTATE_INTERVAL_SECONDS`):

- **when:** daily, *or* as soon as a file passes **32M** (checked every run),
- **keep:** at most **7** rotated copies per file, none older than **14 days**,
  gzip-compressed,
- rsyslogd is HUPed after rotation and reopens its files, so no line is lost
  (no `copytruncate` race).

Worst case is roughly 60M per device, a few hundred MB for the whole fleet,
on a 28G disk.

## Container environment variables

| Variable | Default | Description |
|---|---|---|
| `PASSWORD` | *(unset)* | root password for management SSH. Unset means no password login; use `/container/shell`. Set only via `rsc/secrets.local.rsc`. |
| `LOGROTATE_INTERVAL_SECONDS` | `900` | how often logrotate runs; bounds how far past 32M a file can grow. |
| `TZ` | `Europe/London` | injected by RouterOS from `/system/clock`; drives timestamps and the rotation day. |

## RouterOS setup (`rsc/`)

| Script | Purpose |
|---|---|
| `rsc/secrets.local.rsc` | **git-ignored.** Adds `PASSWORD` to `list=syslog`. Run first. |
| `rsc/01-router-syslog.rsc` | veth `veth-syslog` 192.168.102.3 on `bridge-containers`, env/mount lists, the container, firewall accepts. |
| `rsc/upgrade.rsc` | stop, remove, re-add from the new tar, start, keeping the live settings. |

Deploy and upgrade:

```sh
./build.sh
scp syslog-arm64.tar admin@192.168.20.1:storage/syslog-arm64.tar
# first install only:
scp rsc/secrets.local.rsc  admin@192.168.20.1:storage/syslog-secrets.rsc
scp rsc/01-router-syslog.rsc admin@192.168.20.1:storage/01-router-syslog.rsc
ssh admin@192.168.20.1 '/import file-name=storage/syslog-secrets.rsc; /file remove storage/syslog-secrets.rsc; /import file-name=storage/01-router-syslog.rsc'
# upgrades:
scp rsc/upgrade.rsc admin@192.168.20.1:storage/syslog-upgrade.rsc
ssh admin@192.168.20.1 '/import file-name=storage/syslog-upgrade.rsc'
```

Use `/import` rather than pasting over SSH: RouterOS runs each pasted line as
a separate command, which breaks the `\` continuations.

The firewall accepts (`syslog:` comments) allow `192.168.100.0/24` (mgmt) to
UDP 514/5514 and TCP 5514. They sit **before** the ANYCAST-FW observe
catch-all, so syslog keeps working when that catch-all is flipped to drop.

## Fleet configuration (`../mikrotik`)

Devices are pointed at the collector by the Ansible inventory, `syslog` tag:

- `inventory/group_vars/all.yml`: `system_logging_action_remote: '192.168.102.3'`
- `inventory/group_vars/mikrotik/system_logging_action.yml`: the `remote`
  action, port 5514, `src-address` from `syslog_src_address`
- `inventory/group_vars/mikrotik/system_logging.yml`: the remote rules are
  enabled for `info,!firewall,!fetch`, `error`, `warning` and `critical`.
  Firewall lines are **not** forwarded because of their volume; they stay in
  each device's `fwlog` RAM buffer (`/log print where buffer=fwlog`).
- `host_vars/{router,haxs}/system_logging.yml`: `syslog_src_address` pinned to
  the mgmt IP. Those two would otherwise send from an address with no PTR that
  is outside the mgmt firewall accept.

```sh
cd ../mikrotik
./venv/bin/ansible-playbook playbooks/mikrotik-configure.yml -i inventory/mikrotik --tags syslog
```

## Management

```
/container/shell [find where hostname="syslog-router"]
# tail -f /var/log/remote/all.log
# grep -h 'disconnected' /var/log/remote/hap*.log
# zgrep -h 24:B2:B9:B8:B9:EB /var/log/remote/all.log*
# cat /var/log/remote/.state/logrotate.last
```

Or SSH to `root@192.168.102.3` with the password from `rsc/secrets.local.rsc`.

## Troubleshooting

- **A device's file never appears.** Check its `remote` action
  (`/system logging action print where name=remote`) and that its rules are
  enabled. If it logs from an address outside `192.168.100.0/24`, set
  `syslog_src_address` for it in host_vars.
- **File named by IP instead of host.** No PTR for the sender address: add a
  static A record on the router, or pin `syslog_src_address` to the mgmt IP.
- **Container stopped with "filesystem not mounted".** This is the USB slot
  issue described in the nginx README; the disk must be mounted at `/storage`.
