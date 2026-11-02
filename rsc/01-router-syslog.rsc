# =============================================================================
# Central syslog collector container — Main Router / hub (192.168.20.1)
# Device: MikroTik RB5009UG+S+ (arm64), RouterOS 7.25
# Bridge: existing "bridge-containers", subnet 192.168.102.0/24, gateway
#         192.168.102.1, DHCP pool "continers" 192.168.102.10-200. The syslog
#         container joins it on a NEW veth with a STATIC address OUTSIDE the pool
#         (nginx already has .2; this takes .3).
# Storage: the ext4 USB disk (fs-label "router1-containers") pinned to the FIXED
#   mount-point "storage" — see ../../mikrotik-nginx/rsc/01-router-nginx.rsc
#   STEP 0a for why. Image tar, root-dir and the log mount all live on /storage.
#
# ROLE — receive syslog from every RouterOS device (router, switches, APs) and
#        store it as one file per device plus a combined all.log, rotated by
#        logrotate inside the container (daily or >32M, keep 7, max 14 days).
#        The log directory is a mount, so the files are also visible in the
#        router's own /file menu under storage/syslog/log.
#
#        RouterOS itself can only SEND remote syslog, not receive it; this
#        container is the receiver.
#
# Image: upload the arm64 tar built by ../build.sh -> syslog-arm64.tar
#        (scp syslog-arm64.tar admin@192.168.20.1:storage/).
# =============================================================================

# ADDRESSING:
#   bridge-containers gateway ....... 192.168.102.1  (router, already assigned)
#   DHCP pool "continers" ........... 192.168.102.10-200  (avoid — use static)
#   syslog container veth (veth-syslog) 192.168.102.3/24  (NEW — this script)
#
# Container ports (image, syslog.sh / Dockerfile):
#   5514/udp + 5514/tcp  syslog (fleet default — ../mikrotik inventory
#                        group_vars/mikrotik/system_logging_action.yml)
#   514/udp              syslog (standard port)
#   22/tcp               management SSH
#
# *** RUN rsc/secrets.local.rsc FIRST *** — it adds the management-SSH PASSWORD
# to list=syslog. This script must not contain it.
# =============================================================================

# -----------------------------------------------------------------------------
# STEP 0: Prerequisites (verify — do NOT blindly re-run base router setup)
# -----------------------------------------------------------------------------
#   /system/resource/print          ; architecture-name: arm64 -> syslog-arm64.tar
#   /system/device-mode/print       ; container: yes
#   /interface/bridge/print where name=bridge-containers   ; must exist
#   /disk/print                     ; container disk MOUNTED at "storage"
#   /container/config/print         ; layer-dir=/storage/layers tmpdir=/storage/tmp
#   /file/print where name=storage/syslog-arm64.tar        ; tar uploaded

# -----------------------------------------------------------------------------
# STEP 1: New veth for the syslog container on the EXISTING container bridge
# -----------------------------------------------------------------------------
# Static 192.168.102.3 (outside the DHCP pool .10-200). A fixed address is
# required: every device's remote logging action points at it.
/interface/veth/add \
    name=veth-syslog \
    address=192.168.102.3/24 \
    gateway=192.168.102.1 \
    comment="syslog collector container veth"
/interface/bridge/port/add \
    bridge=bridge-containers \
    interface=veth-syslog

# -----------------------------------------------------------------------------
# STEP 2: Container environment (NON-secret envs only)
# -----------------------------------------------------------------------------
# PASSWORD (management-SSH root password) is added by rsc/secrets.local.rsc —
# RUN THAT FIRST. Omit it entirely to disable password login and use
# /container/shell from the router instead.
#
# TZ is injected by RouterOS from /system/clock (Europe/London), so it is not
# set here. All envs below are optional; the env list must exist for envlists=.
/container/envs/add list=syslog key="LOGROTATE_INTERVAL_SECONDS" value="900"
# --- added by rsc/secrets.local.rsc (run it first) ---
#   PASSWORD = <only in secrets.local.rsc>

# -----------------------------------------------------------------------------
# STEP 3: Mounts — PERSIST the logs (and logrotate state) across restarts
# -----------------------------------------------------------------------------
# Everything the collector writes lives here: <host>.log, all.log, rotated
# *.gz copies, _rsyslogd.log, and .state/ (logrotate state, so "daily" keeps
# its meaning across restarts and upgrade.rsc re-adds).
/container/mounts/add \
    list=syslog \
    src=/storage/syslog/log \
    dst=/var/log/remote \
    mode=rw

# -----------------------------------------------------------------------------
# STEP 4: Add the container
# -----------------------------------------------------------------------------
# cmd is required on RouterOS 7.22+. entrypoint is left EMPTY so the image's
# ENTRYPOINT (syslog-init, the PID 1 that catches SIGTERM) stays in place.
# NOT privileged: a syslog receiver needs no NET_ADMIN/netfilter.
# dns=192.168.102.1: rsyslog reverse-resolves sender IPs through the router,
# whose static *.dids.atasha.net records give PTRs (192.168.100.45 -> hap1).
# restart-policy=on-failure: syslog.sh exits non-zero if rsyslogd dies.
# stop-time=20s: room for rsyslogd to flush its queue on stop.
/container/add \
    file=storage/syslog-arm64.tar \
    interface=veth-syslog \
    envlists=syslog \
    mountlists=syslog \
    hostname=syslog-router \
    dns=192.168.102.1 \
    root-dir=storage/containers/syslog \
    cmd=/usr/local/bin/syslog.sh \
    start-on-boot=yes \
    logging=yes \
    restart-policy=on-failure \
    stop-time=20s \
    comment="syslog collector for the RouterOS fleet (rsyslog + logrotate)"

# -----------------------------------------------------------------------------
# STEP 5: Firewall — allow the fleet's mgmt network to reach the collector
# -----------------------------------------------------------------------------
# Devices log from their mgmt addresses (192.168.100.0/24), which the router
# forwards to the container bridge. The router's OWN logs leave via the output
# chain (src-address=192.168.100.1, see ../mikrotik inventory) and need no rule.
#
# Placed BEFORE the ANYCAST-FW observe catch-all, so syslog keeps working when
# that catch-all is flipped from log+accept to drop (anycast-discovery.md).
# The (...->0) first-match anchor follows the anycast apply scripts.
/ip/firewall/filter/add \
    chain=forward \
    src-address=192.168.100.0/24 \
    dst-address=192.168.102.3 \
    protocol=udp \
    dst-port=514,5514 \
    action=accept \
    comment="syslog: allow mgmt->collector udp 514,5514" \
    place-before=([/ip/firewall/filter/find where comment~"ANYCAST-FW: TODO-DROP"]->0)
/ip/firewall/filter/add \
    chain=forward \
    src-address=192.168.100.0/24 \
    dst-address=192.168.102.3 \
    protocol=tcp \
    dst-port=5514 \
    action=accept \
    comment="syslog: allow mgmt->collector tcp 5514" \
    place-before=([/ip/firewall/filter/find where comment~"ANYCAST-FW: TODO-DROP"]->0)

# -----------------------------------------------------------------------------
# STEP 6: Start the container
# -----------------------------------------------------------------------------
/container/start [find where hostname="syslog-router"]

# -----------------------------------------------------------------------------
# STEP 7: Point the fleet at it (done from ../mikrotik, NOT here)
# -----------------------------------------------------------------------------
# inventory/group_vars/all.yml:
#   mkt_common_settings.system_logging_action_remote: '192.168.102.3'
# inventory/group_vars/mikrotik/system_logging.yml: remote rules enabled.
# inventory/host_vars/{router,haxs}: syslog_src_address pinned to the mgmt IP
#   (router would log as the PTR-less bridge gateway 192.168.102.1; haxs's
#   default route is vlan20, so it would send from 192.168.20.20, outside the
#   mgmt-only accept in STEP 5).

# =============================================================================
# VERIFY
# =============================================================================
#   /container/print                                      ; status running
#   /ip/firewall/filter/print where comment~"syslog:"     ; both accepts, above
#                                                         ; the ANYCAST catch-all
#   /log/info "syslog collector test"                     ; then:
#   /file/print where name~"storage/syslog/log"           ; router.log, all.log
#
#   # inside the container:
#   /container/shell [find where hostname="syslog-router"]
#     ls -la /var/log/remote ; tail /var/log/remote/all.log
#     cat /var/log/remote/.state/logrotate.last           ; last rotation run
#     cat /var/log/remote/_rsyslogd.log                   ; rsyslogd's own msgs
#
# TO REMOVE:
#   /container/stop   [find where hostname="syslog-router"]
#   /container/remove [find where hostname="syslog-router"]
#   /ip/firewall/filter/remove [find comment~"syslog:"]
#   /interface/bridge/port/remove [find interface=veth-syslog]
#   /interface/veth/remove [find name=veth-syslog]
#   /container/envs/remove   [find where list=syslog]
#   /container/mounts/remove [find where list=syslog]
#   (logs stay on disk under /storage/syslog/log until deleted)
# =============================================================================
