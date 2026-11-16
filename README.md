# mikrotik-syslog

A syslog collector for RouterOS devices. It runs rsyslog and logrotate in a [RouterOS container](https://help.mikrotik.com/docs/display/ROS/Container).
RouterOS can send syslog to a remote host but cannot receive it, so this container does the receiving.
It writes one log file per sending device plus a combined `all.log`, and it rotates the files itself.

The examples use a container at `10.0.20.3` on the `bridge-containers` bridge, and a management network `10.0.10.0/24`.
Replace these with your own values.

## Requirements

- RouterOS 7.22 or later with the `container` package, and container mode enabled.
- An ext4 disk mounted at `/storage`. The [mikrotik-nginx README](https://github.com/n4tash4/mikrotik-nginx#pin-the-disk-to-storage) explains how to pin the mount point.
- A bridge named `bridge-containers` with a gateway address for the container subnet. `rsc/01-router-syslog.rsc` attaches the veth to it.
- To build: Docker with Buildx, and `skopeo`.

## Build

```sh
./build.sh              # writes syslog-arm64.tar
NO_CACHE=1 ./build.sh   # clean rebuild
```

The image is arm64 only.
The Dockerfile validates `rsyslog.conf` with `rsyslogd -N1` and `logrotate.conf` with `logrotate -d`. `build.sh` also rejects an image with an empty or duplicate layer, because RouterOS cannot mount one. A failure in either stops the build.

## Paths on the router

| Path | Purpose |
|---|---|
| `/storage/syslog-arm64.tar` | Image file. |
| `/storage/containers/syslog` | Container root-dir. RouterOS deletes it when you remove the container. |
| `/storage/container-data/syslog/log` | Mounted at `/var/log/remote`. All received logs. |
| `/storage/container-data/syslog/ssh-host-keys` | Mounted at `/etc/ssh/host-keys`. SSH host keys. |

The log directory is a RouterOS mount, so the router's `/file` menu shows the files too.

## Environment variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `AUTHORIZED_KEYS` | No | | OpenSSH public keys for `root`, one per line. If unset, SSH login is disabled and the container logs a warning. |
| `LOGROTATE_INTERVAL_SECONDS` | No | `900` | Seconds between logrotate runs. The first run is 30 seconds after start. logrotate checks the size limit only when it runs, so this sets how far a file can grow past 32 MB. The value must be a positive integer, or the container exits at start. |
| `TZ` | No | `Europe/London` | Time zone for log timestamps and the rotation day. `rsc/01-router-syslog.rsc` does not set it, so add it to the env list if you are in another zone. |

## Ports

| Port | Use |
|---|---|
| 5514/udp, 5514/tcp | Syslog. Point the fleet here. |
| 514/udp | Syslog on the standard port. |
| 22/tcp | SSH, public key only. |

## Log files

| File | Contents |
|---|---|
| `<host>.log` | One file per device, for example `router.log`. |
| `all.log` | Lines from every device in the order received. |
| `_rsyslogd.log` | Messages from rsyslogd itself. |
| `*.log-YYYYMMDD-HHMMSS.gz` | Rotated copies. |
| `.state/` | logrotate state and the output of its last run. |

Each line starts with the time the collector received it, not the sender's clock, so a device that has just booted still gets a correct timestamp.
The host name comes from a reverse DNS lookup of the sender address, cut at the first dot. If the address has no PTR record, the file name is the IP address. A name with characters other than letters, digits, `.`, `:`, `_`, and `-` goes to `invalid-host.log`.

logrotate rotates each file daily, or sooner when it reaches 32 MB.
It keeps up to 7 compressed copies and deletes copies older than 14 days.
After a rotation it sends `HUP` to rsyslogd, which reopens its files.

## Process model

```
syslog-init (PID 1)
└── syslog.sh
    ├── rsyslogd -n
    ├── logrotate loop
    └── sshd -D
```

`syslog-init` ([init/main.go](init/main.go)) reaps zombies and forwards signals to `syslog.sh`.
RouterOS sends the stop signal only if PID 1 has a signal handler installed. Without one, it sends `SIGKILL`.
`tini` and `dumb-init` block signals and wait for them, so RouterOS sees no handler and kills them.
If rsyslogd exits, `syslog.sh` stops sshd and the logrotate loop, then exits with rsyslogd's status. With `restart-policy=on-failure`, RouterOS restarts the container.

## Deploy

1. Upload the image:
	```sh
	scp -O syslog-arm64.tar admin@<router>:storage/syslog-arm64.tar
	```
2. In `rsc/01-router-syslog.rsc`, set `AUTHORIZED_KEYS` and the addresses for your network.
3. Upload the script and import it:
	```sh
	scp -O rsc/01-router-syslog.rsc admin@<router>:
	ssh admin@<router> '/import file-name=01-router-syslog.rsc'
	```
	The script creates the veth, the env and mount lists, the container, and two forward-chain accept rules from the management network (UDP 514 and 5514, TCP 5514). It places the rules first in the chain, above any rule that drops forwarded traffic.
4. Wait until `/container/print where hostname="syslog-router"` shows the container as `stopped`. RouterOS extracts the image first, which takes 25 to 50 seconds. Then start it:
	```
	/container/start [find where hostname="syslog-router"]
	```
5. On each device that should send logs, point it at the collector:
	```
	/system/logging/action/add name=remote target=remote remote=10.0.20.3 remote-port=5514
	/system/logging/add topics=info,!firewall action=remote
	/system/logging/add topics=warning action=remote
	/system/logging/add topics=error action=remote
	/system/logging/add topics=critical action=remote
	```

The `info,!firewall` rule leaves out firewall messages, which are high volume.
Set `src-address` on the action if a device would otherwise send from an address that has no PTR record or that the firewall does not accept.

## Verify

1. Check that the container is running:
	```
	/container/print where hostname="syslog-router"
	```
2. On a device that logs to the collector, write a test message:
	```
	/log/warning message="syslog test"
	```
3. On the collector, confirm the line arrived. A file for the device also appears in `/var/log/remote`.
	```sh
	ssh root@10.0.20.3 'grep "syslog test" /var/log/remote/all.log'
	```

## Upgrade

If other containers on the router use the same Debian base, stop all of them before you add the new image.
When a container that shares a layer is running, extraction fails with `Text file busy`.

1. Upload the new `syslog-arm64.tar`.
2. Stop every container: `/container/stop [find]`.
3. Remove the syslog container. The log and host-key mounts keep their data.
4. Add it again with the same settings. Wait until it is `stopped`.
5. Start all containers.

## SSH

`sshd` accepts public keys only, for `root`, and does not allow TCP forwarding. At start, `syslog.sh` writes `AUTHORIZED_KEYS` to `/root/.ssh/authorized_keys`.
It creates the ed25519 and RSA host keys in `/etc/ssh/host-keys` if they are missing, so the fingerprints survive removing and re-adding the container.

```sh
ssh root@10.0.20.3 'tail -f /var/log/remote/all.log'
```

Without SSH, open a shell from the router CLI:

```
/container/shell [find where hostname="syslog-router"]
```

## Troubleshooting

A device's file never appears
: On the device, run `/system/logging/action/print where name=remote` and check the address and port. Check that the firewall accepts the device's source address.

A file is named by IP address
: The sender address has no PTR record. Add a static DNS entry on the router, or set `src-address` on the device's logging action.

`filesystem not mounted?` or `root dir not writable`
: See the troubleshooting section in the [mikrotik-nginx README](https://github.com/n4tash4/mikrotik-nginx#troubleshooting).

## Remove

1. Stop and remove the container, then remove the config that `rsc/01-router-syslog.rsc` added:
	```
	/container/stop [find where hostname="syslog-router"]
	/container/remove [find where hostname="syslog-router"]
	/container/envs/remove [find where list=syslog]
	/container/mounts/remove [find where list=syslog]
	/interface/bridge/port/remove [find where interface=veth-syslog]
	/interface/veth/remove [find where name=veth-syslog]
	/ip/firewall/filter/remove [find where comment~"^syslog:"]
	```
2. Delete `/storage/syslog-arm64.tar`.
3. To delete the collected logs and host keys, delete `/storage/container-data/syslog`. Keep it if you plan to reinstall.
4. Remove the `remote` logging action and its rules on each device.
