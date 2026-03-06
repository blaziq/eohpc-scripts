#!/bin/bash
set -e

MIG_CONFIG="/usr/local/etc/mig-setup.conf"
MIG_SLICES="$(sed 's/^ *//;s/ *$//' 2>/dev/null <${MIG_CONFIG})"
logger -t mig-setup "MIG: '${MIG_SLICES}'"

if [[ "${MIG_SLICES}" == "" ]]; then
    logger -t mig-setup "GPU layout not found in ${MIG_CONFIG}, skipping GPU mig configuration"
    exit 0
fi

if [[ ! ${MIG_SLICES} =~ ^[0-9]+g\.[0-9]+gb(,[0-9]+g\.[0-9]+gb)*$ ]]; then
    logger -t mig-setup "GPU layout invalid value '${MIG_SLICES}' in ${MIG_CONFIG}"
    exit 1
fi

MIG_SLICES_VALS=(${MIG_SLICES//,/ })
AVAILABLE_GI_PROFILES=$(/usr/bin/nvidia-smi mig -lgip | grep -o "[0-9]\+g\.[0-9]\+gb[^[:space:]]*")
for S in ${MIG_SLICES_VALS[@]}; do
    if ! grep -qo "${S}" <<< "${AVAILABLE_GI_PROFILES}"; then
        logger -t mig-setup "GPU layout invalid slice '${S}'"
        exit 1
    fi
done

GPU=0

# Enable MIG (idempotent)
nvidia-smi -i $GPU -mig 1 || true

# Remove existing instances (if any)
nvidia-smi mig -dgi -i $GPU || true
nvidia-smi mig -dci -i $GPU || true

# Create two 20GB instances
nvidia-smi mig -cgi ${MIG_SLICES} -i $GPU
nvidia-smi mig -cci -i $GPU

exit 0
