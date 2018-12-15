#!/usr/bin/env bash
set -o pipefail nounset errexit

# Log output formatters
log_heading() {
  echo ""
  echo "==> $*"
}

log_info() {
  echo "-----> $*"
}

log_error_exit() {
  echo " !  Error:"
  echo " !     $*"
  echo " !     Aborting!"
  exit 1
}

## If SYNC_WINDOWS_FS=true, we will use fat=true in unison profile
#export SYNC_WINDOWS_FS=${SYNC_WINDOWS_FS:=false}


#if [ ! -z "${SYNC_WINDOWS_FS}" ]; then
#  log_heading "Making all SYNC_SOURCE files writable (for Windows NTFS) so they can be written when necessary"
#  sudo chmod -R u+w ${SYNC_SOURCE}
#fi

#
# Set defaults for all variables that we depend on (if they aren't already set in env).
#

# The source for the sync. This will also be recursively monitored by inotifywatch.
: ${SYNC_SOURCE:="/hostmount"}

# The destination for sync. When files are changed in the source, they are automatically
# synced to the destination.
: ${SYNC_DESTINATION:="/fastdockermount"}

# The preferred approach to deal with conflicts
: ${SYNC_PREFER:=$SYNC_SOURCE}

# If set, there will be more verbose log output from various commands that are
# run by this script.
: ${SYNC_VERBOSE:="0"}

# If set, this script will attempt to increase the inotify limit accordingly.
# This option REQUIRES that the container be run as a privileged container.
: ${SYNC_MAX_INOTIFY_WATCHES:=''}

# This variable will be appended to the end of the Unison profile.
: ${SYNC_EXTRA_UNISON_PROFILE_OPTS:=''}

# If set, the source will allow files to be deleted.
: ${SYNC_NODELETE_SOURCE:="0"}

# Healthcheck dir is used to make sure sync is occuring.
# TODO: Remove the directory when stopping container.
export HEALTHCHECK_DIR=${HEALTHCHECK_DIR:-.ddev/.bgsync_healthcheck}

log_heading "Starting bg-sync"

# Dump the configuration to the log to aid bug reports.
log_heading "Configuration:"
log_info "SYNC_SOURCE:                  $SYNC_SOURCE"
log_info "SYNC_DESTINATION:             $SYNC_DESTINATION"
log_info "SYNC_VERBOSE:                 $SYNC_VERBOSE"
if [ -n "${SYNC_MAX_INOTIFY_WATCHES}" ]; then
  log_info "SYNC_MAX_INOTIFY_WATCHES:     $SYNC_MAX_INOTIFY_WATCHES"
fi

# Validate values as much as possible.
[ -d "$SYNC_SOURCE" ] || log_error_exit "Source directory does not exist!"
[ -d "$SYNC_DESTINATION" ] || log_error_exit "Destination directory does not exist!"
[[ "$SYNC_SOURCE" != "$SYNC_DESTINATION" ]] || log_error_exit "Source and destination must be different directories!"

# If SYNC_EXTRA_UNISON_PROFILE_OPTS is set, you're voiding the warranty.
if [ -n "$SYNC_EXTRA_UNISON_PROFILE_OPTS" ]; then
  log_info ""
  log_info "IMPORTANT:"
  log_info ""
  log_info "You have added additional options to the Unison profile. The capability of doing"
  log_info "so is supported, but the results of what Unison might do are *not*."
  log_info ""
  log_info "Proceed at your own risk."
  log_info ""
fi

log_heading "Calculating number of files in $SYNC_SOURCE in the background"
log_info "in order to set fs.inotify.max_user_watches"
sudo sysctl -w fs.inotify.max_user_watches=${SYNC_MAX_INOTIFY_WATCHES:-20000}
/set_max_user_watches.sh ${SYNC_SOURCE} 2>&1 >/dev/stdout &

# Generate a unison profile so that we don't have a million options being passed
# to the unison command.
log_heading "Generating Unison profile"
[ -d "${HOME}/.unison" ] || mkdir -p ${HOME}/.unison

unisonsilent="true"
if [[ "$SYNC_VERBOSE" == "0" ]]; then
  unisonsilent="false"
fi

nodelete=""
if [[ "$SYNC_NODELETE_SOURCE" == "1" ]]; then
  nodelete="nodeletion=$SYNC_SOURCE"
fi

prefer="$SYNC_SOURCE"
if [ -z "${SYNC_PREFER}" ]; then
  prefer=${SYNC_PREFER}
fi

echo "
# This file is automatically generated by bg-sync. Do not modify.

# Sync roots
root = $SYNC_SOURCE
root = $SYNC_DESTINATION

# Sync options
auto=true
backups=false
batch=true
contactquietly=true
fastcheck=true
maxthreads=10
$nodelete
prefer=$SYNC_PREFER
repeat=watch
silent=$unisonsilent
logfile=/dev/stdout
ignore= Name {db_snapshots,.git,.tmp_ddev_composer*}
perms=0
dontchmod=true


# Additional user configuration
$SYNC_EXTRA_UNISON_PROFILE_OPTS

" > ${HOME}/.unison/default.prf

# Wait for the "start sync" flag to appear (typically after docker cp has been done to /destination"
log_heading "Waiting for /var/tmp/unison_start_authorized to appear."

while [ ! -f /var/tmp/unison_start_authorized ]; do
    sleep 1
done

UNISON_UID=$(id -u)
UNISON_GID=$(id -g)
log_heading "Setting up permissions for user uid ${UNISON_UID}."
sudo chown -R ${UNISON_UID}:${UNISON_GID} ${HOME} ${SYNC_DESTINATION}
sudo mkdir -p ${SYNC_SOURCE}/${HEALTHCHECK_DIR} ${SYNC_DESTINATION}/${HEALTHCHECK_DIR}
sudo chmod 777 ${SYNC_SOURCE}/${HEALTHCHECK_DIR} ${SYNC_DESTINATION}/${HEALTHCHECK_DIR}
sudo rm -f ${SYNC_SOURCE}/${HEALTHCHECK_DIR}/* ${SYNC_DESTINATION}/${HEALTHCHECK_DIR}/*

# Start syncing files.
log_heading "Starting unison continuous sync."

exec unison -numericids default