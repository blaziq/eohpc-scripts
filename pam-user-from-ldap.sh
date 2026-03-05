#!/usr/bin/env bash

USER_NAME="${PAM_USER:-${1:-}}"
[[ -n "${USER_NAME}" ]] || exit 0
USER_GROUPS="$(id -nG "${USER_NAME}" 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
HOST_NAME="$(hostname -s | tr '[:upper:]' '[:lower:]')"

ADMINS_GROUP="plesadmins"
PHILAB_GROUP="philab"

check_access() {
    # Allow for all users in ${ADMINS_GROUP} without further checks
    if grep -q " ${ADMINS_GROUP} " <<< " ${USER_GROUPS} "; then
        logger -p authpriv.notice "${0} check_access: Allow for user in group '${ADMINS_GROUP}', user=${USER_NAME} host=${HOST_NAME} groups=(${USER_GROUPS})"
        exit 0
    fi
    # Deny to users in ${PHILAB_GROUP} who dont have a relevant group corresponding to ${HOST_NAME}
    if grep -q " ${PHILAB_GROUP} " <<< " ${USER_GROUPS} " && ! grep -q " ${HOST_NAME}[ _]" <<< " ${USER_GROUPS} " ; then
        logger -p authpriv.notice "${0} check_access: Deny for user in group '${PHILAB_GROUP}' without '${HOST_NAME}*' group, user=${USER_NAME} host=${HOST_NAME} groups=(${USER_GROUPS})"
        exit 1
    fi
    # Allow users in ${PHILAB_GROUP} who dont have a relevant group corresponding to ${HOST_NAME}
    # and other users who went through access.conf
    logger -p authpriv.notice "${0} check_access: Allow for user=${USER_NAME} host=${HOST_NAME} groups=(${USER_GROUPS})"
    exit 0
}

set_quotas() {
    local USER_ID="$(id -u ${USER_NAME})"
    local SLICE="user-${USER_ID}.slice"
    
    # if session is being closed - exit
    [[ "${PAM_TYPE}" == "close_session" ]] && exit 0

    # Assume only one group should match; we take the first valid one.
    match=""
    for g in ${USER_GROUPS}; do
        [[ "$g" == "${HOST_NAME}" || "$g" == "${HOST_NAME}_"* ]] || continue
        # Validate: must not have more than 3 underscores after "host" i.e. total fields must be 1..4
        nf="$(awk -F_ '{print NF}' <<< "${g}")"
        if (( nf >= 1 && nf <= 4 )); then
            f1="$(awk -F_ '{print $1}' <<< "${g}")"
            if [[ "${f1}" == "${HOST_NAME}" ]]; then
                match="${g}"
                break
            fi
        fi
    done

    [[ -z "${match}" ]] && exit 0

    CPU_QUOTA=""
    MEM_QUOTA=""
    GPU_QUOTA=""
    GPU_DEVICES=""

    if [[ ${match} =~ (^|_)cpu([0-9]+)($|_) ]]; then CPU_QUOTA="${BASH_REMATCH[2]}"; fi
    if [[ ${match} =~ (^|_)mem([0-9]+)($|_) ]]; then MEM_QUOTA="${BASH_REMATCH[2]}"; fi
    if [[ ${match} =~ (^|_)gpu([0-9]+)($|_) ]]; then GPU_QUOTA="${BASH_REMATCH[2]}"; fi

    # The CPU quota in the groups is the number of CPUs available to the user
    # It must be multiplied by 100 to get the percent of the CPU quota to apply
    [[ ${CPU_QUOTA} =~ ^[0-9]+ ]] && CPU_QUOTA="$(( ${CPU_QUOTA} * 100 ))%" || CPU_QUOTA=""

    # Only set RAM quota if the value in the group is a number, add G suffix for gigabytes
    [[ ${MEM_QUOTA} =~ ^[0-9]+ ]] && MEM_QUOTA="${MEM_QUOTA}G" || MEM_QUOTA=""

    # GPU quota
    [[ ! ${GPU_QUOTA} =~ ^[0-9]+ ]] && GPU_QUOTA=""
    GPU_DEVICES=$(/usr/local/sbin/pam-user-gpu-devices.py "${GPU_QUOTA}")
    
    # This sets the slice quota in runtime so it is not permanent but active until next login or reboot
    # There'll be no setting in /etc/systemd/system.control/${SLICE}
    # but only in /run/systemd/system.control/${SLICE}.d
    logger -p authpriv.notice "${0} set_quotas: Setting quotas for user \"${SLICE}\" CPUQuota=\"${CPU_QUOTA}\" MemoryMax=\"${MEM_QUOTA}\" MemorySwapMax=0 ${GPU_DEVICES}"
    # First reset to default so that new settings can be applied from scratch
    systemctl revert "${SLICE}"
    # And then apply the quotas
    systemctl set-property --runtime "${SLICE}" \
        CPUQuota="${CPU_QUOTA}" \
        MemoryMax="${MEM_QUOTA}" \
        MemorySwapMax=0 \
        ${GPU_DEVICES}
}

# run function based on the actual script (symlink) name
tmp="${0#*-*-}"      # remove first two dash-separated fields
tmp="${tmp%.*}"      # and the .sh extension
func="${tmp//-/_}"
if declare -F ${func} &> /dev/null; then
    $func
    exit $?
fi
exit 1
