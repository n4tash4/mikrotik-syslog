/interface/veth/add name=veth-syslog address=10.0.20.3/24 gateway=10.0.20.1 \
    comment="syslog container"
/interface/bridge/port/add bridge=bridge-containers interface=veth-syslog

/container/envs/add list=syslog key="LOGROTATE_INTERVAL_SECONDS" value="900"
/container/envs/add list=syslog key="AUTHORIZED_KEYS"            value="<your-ssh-public-key>"

/container/mounts/add list=syslog src=/storage/container-data/syslog/log           dst=/var/log/remote    mode=rw
/container/mounts/add list=syslog src=/storage/container-data/syslog/ssh-host-keys dst=/etc/ssh/host-keys mode=rw

/container/add file=storage/syslog-arm64.tar interface=veth-syslog \
    envlists=syslog mountlists=syslog hostname=syslog-router \
    dns=10.0.20.1 root-dir=/storage/containers/syslog \
    cmd=/usr/local/bin/syslog.sh start-on-boot=yes logging=yes \
    restart-policy=on-failure stop-time=20s \
    comment="syslog collector (rsyslog + logrotate)"

/ip/firewall/filter/add chain=forward action=accept protocol=udp \
    src-address=10.0.10.0/24 dst-address=10.0.20.3 dst-port=514,5514 \
    place-before=0 comment="syslog: devices to collector, udp"
/ip/firewall/filter/add chain=forward action=accept protocol=tcp \
    src-address=10.0.10.0/24 dst-address=10.0.20.3 dst-port=5514 \
    place-before=0 comment="syslog: devices to collector, tcp"
