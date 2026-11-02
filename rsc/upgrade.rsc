# =============================================================================
# Upgrade/redeploy the syslog collector container — Main Router (192.168.20.1)
#
# Mirrors ../../mikrotik-nginx/rsc/upgrade.rsc: capture the live container's
# settings, stop -> remove -> re-add from the LOCAL tar -> start. The re-add
# uses file=storage/syslog-arm64.tar + cmd=/usr/local/bin/syslog.sh (matching
# 01-router-syslog.rsc STEP 4).
#
# Upload the new syslog-arm64.tar to /storage BEFORE running this. The log
# mount (/storage/syslog/log), including logrotate's state, survives the re-add.
#
# While the container is down (~30s) devices keep sending UDP syslog, which is
# simply lost for that window; RouterOS does not buffer remote log lines.
# =============================================================================

# Container identifier
:local hostname "syslog-router";
/container
:local id [find where hostname=$hostname];
:local rootdir [get $id root-dir];
:local dns [get $id dns];
:local logging [get $id logging];
:local status [get $id status];
:local mounts [get $id mountlists];
:local envlist [get $id envlists];
:local interface [get $id interface];
:local startonboot [get $id start-on-boot];
:local restartpolicy [get $id restart-policy];
:local stoptime [get $id stop-time];
:global LogPrefix "Syslog";
:local logI do={
    :global LogPrefix;
    :put ($LogPrefix . ": " . $1);
    :log info ($LogPrefix . ": " . $1);
}

# Stop the container
$logI "Stopping the container...";
stop $id
:while ($status != "stopped") do={
    $logI "Waiting for the container to stop...";
    :delay 5;
    :set status [get $id status];
}
$logI "Stopped.";

# Remove the container
remove $id
$logI "Removing the container...";
:while ($status = "stopped") do={
    $logI "Waiting for the container to be removed...";
    :delay 5;
    :set status [get $id status];
}
$logI "Removed.";

# Add the container (from the LOCAL tar). cmd is required on RouterOS 7.22+.
:delay 5;
$logI "Adding the container...";
add file=storage/syslog-arm64.tar cmd=/usr/local/bin/syslog.sh \
    interface=$interface envlists=$envlist root-dir=$rootdir mountlists=$mounts \
    start-on-boot=$startonboot hostname=$hostname dns=$dns logging=$logging \
    restart-policy=$restartpolicy stop-time=$stoptime \
    comment="syslog collector for the RouterOS fleet (rsyslog + logrotate)"
:do {
    :set status [get [find where hostname=$hostname] status];
    :if ($status != "stopped") do={
        $logI "Waiting for the container to be added...";
        :delay 5;
    }
} while ($status != "stopped")
$logI "Added."

# Start the container
$logI "Starting the container.";
:set id [find where hostname=$hostname];
start $id
