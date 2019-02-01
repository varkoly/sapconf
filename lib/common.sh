#!/usr/bin/env bash
# shellcheck disable=SC1091

# common.sh implements common tuning techniques that are universally applied to many SAP softwares.
# Authors:
#   Angela Briel <abriel@suse.com>
#   Howard Guo <hguo@suse.com>

. /usr/lib/tuned/functions
cd /usr/lib/sapconf || exit 1
. util.sh

# tune_preparation applies tuning techniques from "1275776 - Preparing SLES for SAP" and "1984787 - Installation notes".
tune_preparation() {
    log "--- Going to apply universal tuning techniques"

    # Bunch of variables declared in upper case
    declare VSZ_TMPFS_PERCENT=0
    declare TMPFS_SIZE_REQ=0
    VSZ_tmp=$(awk -v t=0 '/^(Mem|Swap)Total:/ {t+=$2} END {print t}' < /proc/meminfo) # total (system+swap) memory size in KB
    declare -r VSZ=$VSZ_tmp
    declare TMPFS_OPTS
    declare TMPFS_SIZE

    # semaphore variables
    declare SEMMSLCUR
    declare SEMMNSCUR
    declare SEMOPMCUR
    declare SEMMNICUR

    # Read value requirements from sysconfig, the declarations will set variables above.
    if [ -r /etc/sysconfig/sapconf ]; then
        source_sysconfig /etc/sysconfig/sapconf
    else
        log 'Failed to read /etc/sysconfig/sapconf'
        exit 1
    fi

    # paranoia: should not happen, because post script of package installation
    # should rewrite variable names. But....
    for par in SHMALL_MIN SHMMAX_MIN SEMMSL_MIN SEMMNS_MIN SEMOPM_MIN SEMMNI_MIN MAX_MAP_COUNT_DEF SHMMNI_DEF DIRTY_BYTES_DEF DIRTY_BG_BYTES_DEF; do
        npar=${par%_*}
        if [ -n "${!par}" ] && [ -z "${!npar}" ]; then
            # the only interesting case:
            # the old variable name is declared in the sysconfig file, but
            # NOT the new variable name
            # So set the new variable name  with the value of the old one
            declare $npar=${!par}
        fi
    done

    ## Collect current information

    # semaphore settings
    read -r SEMMSLCUR SEMMNSCUR SEMOPMCUR SEMMNICUR < <(sysctl -n kernel.sem)
    # Mount - tmpfs mount options and size
    # disable shell check for throwaway variable 'discard'
    # shellcheck disable=SC2034
    read -r discard discard discard TMPFS_OPTS discard < <(grep -E '^tmpfs /dev/shm .+' /proc/mounts)
    if [ ! "$TMPFS_OPTS" ]; then
        log "The system does not use tmpfs. Please configure tmpfs and try again."
        exit 1
    fi
    # Remove size= from mount options
    TMPFS_OPTS=$(echo "$TMPFS_OPTS" | sed 's/size=[^,]\+//' | sed 's/^,//' | sed 's/,$//' | sed 's/,,/,/')
    TMPFS_SIZE=$(($(stat -fc '(%b*%S)>>10' /dev/shm))) # in KBytes

    ## Calculate recommended value

    # 1275776 - Preparing SLES for SAP
    TMPFS_SIZE_REQ=$(math "$VSZ*$VSZ_TMPFS_PERCENT/100")

    ## Apply new parameters

    # Enlarge tmpfs
    if [ "$(math_test "$TMPFS_SIZE_REQ > $TMPFS_SIZE")" ]; then
        log "Increasing size of /dev/shm from $TMPFS_SIZE to $TMPFS_SIZE_REQ"
        save_value tmpfs.size "$TMPFS_SIZE"
        save_value tmpfs.mount_opts "$TMPFS_OPTS"
        mount -o "remount,${TMPFS_OPTS},size=${TMPFS_SIZE_REQ}k" /dev/shm
    elif [ "$(math_test "$TMPFS_SIZE_REQ <= $TMPFS_SIZE")" ]; then
        log "Leaving size of /dev/shm untouched at $TMPFS_SIZE"
    fi
    # Tweak shm
    save_value kernel.shmmax "$(sysctl -n kernel.shmmax)"
    chk_and_set_conf_val SHMMAX kernel.shmmax
    save_value kernel.shmall "$(sysctl -n kernel.shmall)"
    chk_and_set_conf_val SHMALL kernel.shmall
    # Tweak semaphore
    SEMMSL=$(chk_conf_val SEMMSL "$SEMMSLCUR")
    SEMMNS=$(chk_conf_val SEMMNS "$SEMMNSCUR")
    SEMOPM=$(chk_conf_val SEMOPM "$SEMOPMCUR")
    SEMMNI=$(chk_conf_val SEMMNI "$SEMMNICUR")
    if [ "$SEMMSLCUR $SEMMNSCUR $SEMOPMCUR $SEMMNICUR" != "$SEMMSL $SEMMNS $SEMOPM $SEMMNI" ]; then
        save_value kernel.sem "$(sysctl -n kernel.sem)"
        log "Change kernel.sem from '$SEMMSLCUR $SEMMNSCUR $SEMOPMCUR $SEMMNICUR' to '$SEMMSL $SEMMNS $SEMOPM $SEMMNI'"
        sysctl -w "kernel.sem=$SEMMSL $SEMMNS $SEMOPM $SEMMNI"
    else
        log "Leaving kernel.sem unchanged at '$SEMMSLCUR $SEMMNSCUR $SEMOPMCUR $SEMMNICUR'"
    fi
    # Tweak max_map_count
    save_value vm.max_map_count "$(sysctl -n vm.max_map_count)"
    chk_and_set_conf_val MAX_MAP_COUNT vm.max_map_count

    # Tune ulimits for the max number of open files (rollback is not necessary in revert function)
    all_nofile_limits=""
    for limit in ${!LIMIT_*}; do # LIMIT_ parameters are defined in sysconfig file
        all_nofile_limits="$all_nofile_limits\\n${!limit}"
    done
    for ulimit_group in @sapsys @sdba @dba; do
        for ulimit_type in soft hard; do
            sysconf_line=$(echo -e "$all_nofile_limits" | grep -E "^${ulimit_group}[[:space:]]+${ulimit_type}[[:space:]]+nofile.+")
            limits_line=$(grep -E "^${ulimit_group}[[:space:]]+${ulimit_type}[[:space:]]+nofile.+" /etc/security/limits.conf)
            # Remove previously entered limits line so that new line may be inserted
            if [ "$limits_line" ]; then
                sed -i "/$limits_line/d" /etc/security/limits.conf
            fi
            echo "$sysconf_line" >> /etc/security/limits.conf
        done
    done

    log "--- Finished application of universal tuning techniques"
}

# revert_preparation reverts tuning operations conducted by "1275776 - Preparing SLES for SAP" and "1984787 - Installation notes".
revert_preparation() {
    log "--- Going to revert universally tuned parameters"
    # Restore tuned kernel parameters
    SHMMAX=$(restore_value kernel.shmmax)
    [ "$SHMMAX" ] && log "Restoring kernel.shmmax=$SHMMAX" && sysctl -w kernel.shmmax="$SHMMAX"


    SHMALL=$(restore_value kernel.shmall)
    [ "$SHMALL" ] && log "Restoring kernel.shmall=$SHMALL" && sysctl -w kernel.shmall="$SHMALL"

    SEM=$(restore_value kernel.sem)
    [ "$SEM" ] && log "Restoring kernel.sem=$SEM" && sysctl -w kernel.sem="$SEM"

    MAX_MAP_COUNT=$(restore_value vm.max_map_count)
    [ "$MAX_MAP_COUNT" ] && log "Restoring vm.max_map_count=$MAX_MAP_COUNT" && sysctl -w vm.max_map_count="$MAX_MAP_COUNT"

    # Restore the size of tmpfs
    TMPFS_SIZE=$(restore_value tmpfs.size)
    TMPFS_OPTS=$(restore_value tmpfs.mount_opts)
    [ "$TMPFS_SIZE" ] && [ -e /dev/shm ] && mount -o "remount,${TMPFS_OPTS},size=${TMPFS_SIZE}k" /dev/shm
    log "--- Finished reverting universally tuned parameters"
}

# tune_page_cache_limit optimises page cache limit according to recommendation in "1557506 - Linux paging improvements".
tune_page_cache_limit() {
    log "--- Going to tune page cache limit using the recommendations defined in /etc/sysconfig/sapconf"
    if [ ! -f /proc/sys/vm/pagecache_limit_mb ]; then
        log "pagecache limit is not supported by os, skipping."
        return
    fi
    declare ENABLE_PAGECACHE_LIMIT="no"
    # The configuration file should overwrite the three parameters above
    if [ -r /etc/sysconfig/sapconf ]; then
        source_sysconfig /etc/sysconfig/sapconf
    fi
    if [ "$ENABLE_PAGECACHE_LIMIT" = "yes" ]; then
        if [ -z "$PAGECACHE_LIMIT_MB" ]; then
                log "ATTENTION: PAGECACHE_LIMIT_MB not set in sysconfig file."
                log "Disabling page cache limit"
                PAGECACHE_LIMIT_MB="0"
        fi
        save_value vm.pagecache_limit_mb "$(sysctl -n vm.pagecache_limit_mb)"
        log "Setting vm.pagecache_limit_mb=$PAGECACHE_LIMIT_MB"
        sysctl -w "vm.pagecache_limit_mb=$PAGECACHE_LIMIT_MB"
        if [ -z "$PAGECACHE_LIMIT_IGNORE_DIRTY" ]; then
                log "ATTENTION: PAGECACHE_LIMIT_IGNORE_DIRTY not set in sysconfig file."
                log "Setting system default '0'"
                PAGECACHE_LIMIT_IGNORE_DIRTY="0"
        fi
        # Set ignore_dirty
        save_value vm.pagecache_limit_ignore_dirty "$(sysctl -n vm.pagecache_limit_ignore_dirty)"
        log "Setting vm.pagecache_limit_ignore_dirty=$PAGECACHE_LIMIT_IGNORE_DIRTY"
        sysctl -w "vm.pagecache_limit_ignore_dirty=$PAGECACHE_LIMIT_IGNORE_DIRTY"
    else
        # Disable pagecache limit by setting it to 0
        save_value vm.pagecache_limit_mb "$(sysctl -n vm.pagecache_limit_mb)"
        log "Disabling page cache limit"
        sysctl -w "vm.pagecache_limit_mb=0"
    fi
    log "--- Finished application of page cache limit"
}

# revert_page_cache_limit reverts page cache limit parameter value tuned by either NetWeaver or HANA recommendation.
revert_page_cache_limit() {
    log "--- Going to revert page cache limit"
    # Restore pagecache settings
    PAGECACHE_LIMIT=$(restore_value vm.pagecache_limit_mb)
    [ "$PAGECACHE_LIMIT" ] && log "Restoring vm.pagecache_limit_mb=$PAGECACHE_LIMIT" && sysctl -w "vm.pagecache_limit_mb=$PAGECACHE_LIMIT"
    PAGECACHE_LIMIT_IGNORE_DIRTY=$(restore_value vm.pagecache_limit_ignore_dirty)
    [ "$PAGECACHE_LIMIT_IGNORE_DIRTY" ] && log "Restoring vm.pagecache_limit_ignore_dirty=$PAGECACHE_LIMIT_IGNORE_DIRTY" && sysctl -w "vm.pagecache_limit_ignore_dirty=$PAGECACHE_LIMIT_IGNORE_DIRTY"
    log "--- Finished reverting page cache limit"
}

# tune_uuidd_socket unconditionally enables and starts uuidd.socket as recommended in "1984787 - Installation notes".
tune_uuidd_socket() {
    if ! systemctl is-active uuidd.socket; then
        # paranoia: should not happen, because uuidd.socket should be enabled
        # by vendor preset and sapconf.service should start uuidd.socket.
        log "--- Going to enable and start uuidd.socket"
        systemctl enable uuidd.socket
        systemctl start uuidd.socket
    fi
}

# revert_shmmni reverts kernel.shmmni value to previous state.
revert_shmmni() {
    SHMMNI=$(restore_value kernel.shmmni)
    [ "$SHMMNI" ] && log "Restoring kernel.shmmni=$SHMMNI" && sysctl -w "kernel.shmmni=$SHMMNI"
}
