#!/usr/bin/env bash

SCRIPT_DIR="/usr/local/sbin"
PAM_DIR="/etc/pam.d"

BASE="pam-user-from-ldap.sh"
CHECK_ACCESS="pam-user-check-access.sh"
SET_QUOTAS="pam-user-set-quotas.sh"
GPU_DEVICES="pam-user-gpu-devices.py"

# --------------------------------------------------------------------------------
# 1. Create a script to check user access based on groups and set resource quotas
# --------------------------------------------------------------------------------
SCRIPT_BASE="${SCRIPT_DIR}/${BASE}"
SCRIPT_CHECK_ACCESS="${SCRIPT_DIR}/${CHECK_ACCESS}"
SCRIPT_SET_QUOTAS="${SCRIPT_DIR}/${SET_QUOTAS}"
SCRIPT_GPU_DEVICES="${SCRIPT_DIR}/${GPU_DEVICES}"

install -m 711 ${BASE} ${SCRIPT_BASE}
install -m 711 ${GPU_DEVICES} ${SCRIPT_GPU_DEVICES}
ln -sfr ${SCRIPT_BASE} ${SCRIPT_CHECK_ACCESS}
ln -sfr ${SCRIPT_BASE} ${SCRIPT_SET_QUOTAS}

# --------------------------------------------------------------------------------
# 2. Allow logind to communicate with the LDAP server
# --------------------------------------------------------------------------------
LOGIND_OVERRIDE_CONF="/etc/systemd/system/systemd-logind.service.d/override.conf"
# Fix logind configuration to allow configuration with LDAP
cat << 'EOF' > "${LOGIND_OVERRIDE_CONF}"
[Service]
RestrictAddressFamilies=AF_UNIX AF_NETLINK AF_INET
IPAddressAllow=10.0.0.0/24
EOF
systemctl daemon-reload
systemctl restart systemd-logind

# --------------------------------------------------------------------------------
# 3. Let all users from group 'philab' through in /etc/security/access.conf
#    They will be later allowed or denied by checking groups in the script
# --------------------------------------------------------------------------------
ACCESS_CONFIG="/etc/security/access.conf"
ACCESS_ALLOW_PHILAB="+:(philab):ALL"

grep -Fqx "${ACCESS_ALLOW_PHILAB}" "${ACCESS_CONFIG}" || \
    sed -i "/^-:ALL:ALL[[:space:]]*$/i ${ACCESS_ALLOW_PHILAB}" "${ACCESS_CONFIG}"
    
# --------------------------------------------------------------------------------
# 4. Check access in PAM based on user groups from LDAP
# --------------------------------------------------------------------------------
PAM_CONFIG_SSHD="${PAM_DIR}/sshd"
PAM_INCLUDE_CHECK_ACCESS="@include ${CHECK_ACCESS}"

cat << EOF > "${PAM_DIR}/${CHECK_ACCESS}"
account required pam_exec.so quiet ${SCRIPT_CHECK_ACCESS}
EOF

grep -Fqx "${PAM_INCLUDE_CHECK_ACCESS}" "${PAM_CONFIG_SSHD}" || \
    sed -i "/^@include[[:space:]]\\+common-account[[:space:]]*$/i ${PAM_INCLUDE_CHECK_ACCESS}" "${PAM_CONFIG_SSHD}"

# --------------------------------------------------------------------------------
# 5. Set up CPU and RAM quotas in PAM user session:
# --------------------------------------------------------------------------------
PAM_CONFIG_SESSION="/etc/pam.d/common-session"
PAM_INCLUDE_SET_QUOTAS="@include ${SET_QUOTAS}"

cat << EOF > "${PAM_DIR}/${SET_QUOTAS}"
session optional pam_exec.so seteuid ${SCRIPT_SET_QUOTAS}
EOF

grep -Fqx "${PAM_INCLUDE_SET_QUOTAS}" ${PAM_CONFIG_SESSION} || \
    echo "${PAM_INCLUDE_SET_QUOTAS}" >> ${PAM_CONFIG_SESSION}
