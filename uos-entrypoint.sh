#!/bin/bash

log() {
    echo "[uos-entrypoint][$(date -Iseconds)] $*"
}

# This is a template entrypoint script.
# The workflow will use version-specific scripts from versions/{VERSION}/ when available.

# Persist UOS_UUID env var
if [ ! -f /data/uos_uuid ]; then
    if [ -n "${UOS_UUID+1}" ]; then
        log "Setting UUID to $UOS_UUID"
        echo "$UOS_UUID" > /data/uos_uuid
    else
        log "No UUID present, generating"
        UUID=$(cat /proc/sys/kernel/random/uuid)

        # Spoof a v5 UUID
        UOS_UUID=$(echo $UUID | sed s/./5/15)
        log "Setting UUID to $UOS_UUID"
        echo "$UOS_UUID" > /data/uos_uuid
    fi
fi

# Read version from package.json and write version string
log "Setting UOS_SERVER_VERSION to $UOS_SERVER_VERSION"
echo "UOSSERVER.0000000.$UOS_SERVER_VERSION.0000000.000000.0000" > /usr/lib/version
log "Setting FIRMWARE_PLATFORM to $FIRMWARE_PLATFORM"
echo "$FIRMWARE_PLATFORM" > /usr/lib/platform

# Create eth0 alias if missing (requires NET_ADMIN cap & macvlan kernel module loaded on host).
# Checks tap0 first (VPN/hypervisor envs), then falls back to the host's default-route interface.
if [ ! -d "/sys/devices/virtual/net/eth0" ]; then
    if [ -d "/sys/devices/virtual/net/tap0" ]; then
        PARENT_IF="tap0"
    else
        PARENT_IF=$(ip route show default 2>/dev/null | awk '/default via/ {print $5; exit}')
    fi

    if [ -n "$PARENT_IF" ]; then
        log "Creating eth0 macvlan alias from $PARENT_IF"
        ip link add name eth0 link "$PARENT_IF" type macvlan
        ip link set eth0 up
    else
        log "WARNING: could not determine parent interface for eth0 alias"
    fi
fi

# Initialize nginx log dirs
NXINX_LOG_DIR="/var/log/nginx"
if [ ! -d "$NXINX_LOG_DIR" ]; then
    log "Initializing nginx log dir at $NXINX_LOG_DIR"
    mkdir -p "$NXINX_LOG_DIR"
    chown nginx:nginx "$NXINX_LOG_DIR"
    chmod 755 "$NXINX_LOG_DIR"
fi

# Initialize mongodb log dirs
MONGODB_LOG_DIR="/var/log/mongodb"
if [ ! -d "$MONGODB_LOG_DIR" ]; then
    log "Initializing mongodb log dir at $MONGODB_LOG_DIR"
    mkdir -p "$MONGODB_LOG_DIR"
    chown mongodb:mongodb "$MONGODB_LOG_DIR"
    chmod 755 "$MONGODB_LOG_DIR"
fi

# Initialize mongodb lib dirs
MONGODB_LIB_DIR="/var/lib/mongodb"
log "Ensuring mongodb ownership for $MONGODB_LIB_DIR"
chown -R mongodb:mongodb "$MONGODB_LIB_DIR"

# Initialize rabbitmq log dirs
RABBITMQ_LOG_DIR="/var/log/rabbitmq"
if [ ! -d "$RABBITMQ_LOG_DIR" ]; then
    log "Initializing rabbitmq log dir at $RABBITMQ_LOG_DIR"
    mkdir -p "$RABBITMQ_LOG_DIR"
    chown rabbitmq:rabbitmq "$RABBITMQ_LOG_DIR"
    chmod 755 "$RABBITMQ_LOG_DIR"
fi

# # Apply Synology patches
# SYS_VENDOR="/sys/class/dmi/id/sys_vendor"
# if [ -f "$SYS_VENDOR" ] && grep -q "Synology Inc." "$SYS_VENDOR"; then
#     log "Synology hardware found, applying patches"

#     # Set Postgres overrides
#     mkdir -p /etc/systemd/system/postgresql@14-main.service.d
#     {
#         echo "[Service]"
#         echo "PIDFile="
#     } > /etc/systemd/system/postgresql@14-main.service.d/override.conf

#     # Set RabbitMQ overrides
#     mkdir -p /etc/systemd/system/rabbitmq-server.service.d
#     {
#         echo "[Service]"
#         echo "Type=simple"
#     } > /etc/systemd/system/rabbitmq-server.service.d/override.conf

#     # Set ulp-go overrides
#     mkdir -p /etc/systemd/system/ulp-go.service.d
#     {
#         echo "[Service]"
#         echo "Type=simple"
#     } > /etc/systemd/system/ulp-go.service.d/override.conf

#     log "Synology patches applied"
# fi

# Set UOS_SYSTEM_IP (required)
if [ -z "${UOS_SYSTEM_IP}" ]; then
    log "ERROR: UOS_SYSTEM_IP is required but not set"
    exit 1
fi
UNIFI_SYSTEM_PROPERTIES="/var/lib/unifi/system.properties"

set_property() {
    local key="$1" value="$2"
    local escaped_value="${value//\\/\\\\}"
    escaped_value="${escaped_value//&/\\&}"
    if grep -q "^${key}=" "$UNIFI_SYSTEM_PROPERTIES" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${escaped_value}|" "$UNIFI_SYSTEM_PROPERTIES"
    else
        echo "${key}=${value}" >> "$UNIFI_SYSTEM_PROPERTIES"
    fi
}

MONGO_HOST="${MONGO_HOST:-unifi-os-server-mongodb}"
MONGO_PORT="${MONGO_PORT:-27017}"
MONGO_USER="${MONGO_USER:-root}"
MONGO_PASS="${MONGO_PASS:-root}"
MONGO_TLS="${MONGO_TLS:-false}"
MONGO_AUTH_SOURCE="${MONGO_AUTH_SOURCE-admin}"

MONGO_URI="mongodb\\://${MONGO_USER}\\:${MONGO_PASS}@${MONGO_HOST}\\:${MONGO_PORT}"
MONGO_PARAMS="tls\\=${MONGO_TLS}"
if [ -n "${MONGO_AUTH_SOURCE}" ]; then
    MONGO_PARAMS="${MONGO_PARAMS}&authSource\\=${MONGO_AUTH_SOURCE}"
fi

log "Configuring system.properties with UOS_SYSTEM_IP=$UOS_SYSTEM_IP and MongoDB target ${MONGO_HOST}:${MONGO_PORT}"
set_property "system_ip" "$UOS_SYSTEM_IP"
set_property "db.mongo.local" "false"
set_property "db.mongo.uri" "${MONGO_URI}/ace?${MONGO_PARAMS}"
set_property "statdb.mongo.uri" "${MONGO_URI}/ace_stat?${MONGO_PARAMS}"

# Apply custom system.properties from UNIFI_SYSPROP_* env vars.
# Double underscores in the var name become dots in the property key.
#   UNIFI_SYSPROP_db__mongo__local=false  →  db.mongo.local=false
#   UNIFI_SYSPROP_system_ip=10.0.0.1      →  system_ip=10.0.0.1
# while IFS= read -r line; do
#     envname="${line%%=*}"
#     envvalue="${line#*=}"
#     propkey="${envname#UNIFI_SYSPROP_}"
#     propkey="${propkey//__/.}"
#     log "Setting system.properties (env override): ${propkey}=${envvalue}"
#     set_property "$propkey" "$envvalue"
# done < <(env | grep '^UNIFI_SYSPROP_')

# Remove the duplicate mongo server /usr/bin/mongod
if [ -f "/usr/bin/mongod" ]; then
    log "Removing duplicate /usr/bin/mongod binary"
    rm -f /usr/bin/mongod
fi

# Inject localhost bypass (port 7443 → controller on 8081, skipping UOS SSO).
# Runs as a persistent background watcher because UOS regenerates the nginx
# config directory on restart / config changes, which removes our file.
# (
#     BYPASS_SRC="/root/site-localhost-bypass.conf"
#     CONFIG_DIR="/data/unifi-core/config/http"
#     CONFIG_FILE="${CONFIG_DIR}/site-localhost-bypass.conf"
#     UOS_SOCK="/data/unifi-core/config/http/uos-http.sock"
#     BYPASS_HASH=$(md5sum "$BYPASS_SRC" | awk '{print $1}')

#     # Wait for UOS API to be fully ready before first injection, so we don't
#     # get overwritten by UOS still generating its own nginx configs.
#     log "Localhost bypass: watcher started, waiting for UOS API"
#     while ! curl -sf --unix-socket "$UOS_SOCK" http://localhost/api/system > /dev/null 2>&1; do
#         sleep 10
#     done
#     log "Localhost bypass: UOS API is ready"

#     while true; do
#         # (Re-)inject if the file is missing or has been modified
#         CURRENT_HASH=$(md5sum "$CONFIG_FILE" 2>/dev/null | awk '{print $1}')
#         if [ "$CURRENT_HASH" != "$BYPASS_HASH" ]; then
#             cp "$BYPASS_SRC" "$CONFIG_FILE"
#             # Full restart required: reload reuses existing sockets and won't
#             # pick up changes to listen directives.
#             nginx -s quit 2>/dev/null || true
#             sleep 2
#             nginx 2>/dev/null || true
#             log "Localhost bypass: injected on port 7443"
#         fi

#         sleep 30
#     done
# ) &

# # Expose PostgreSQL on all interfaces so Docker port mapping can reach it.
# # listen_addresses requires a restart (reload is not enough).
# (
#     PG_CONF="/etc/postgresql/14/main/postgresql.conf"
#     PG_HBA="/etc/postgresql/14/main/pg_hba.conf"

#     log "PostgreSQL exposure worker started"
#     while [ ! -f "$PG_CONF" ]; do sleep 5; done

#     if grep -q "^#\?listen_addresses" "$PG_CONF"; then
#         sed -i "s/^#\?listen_addresses.*/listen_addresses = '*' /" "$PG_CONF"
#     else
#         echo "listen_addresses = '*'" >> "$PG_CONF"
#     fi

#     if ! grep -q "^host all all 0.0.0.0/0" "$PG_HBA" 2>/dev/null; then
#         echo "host all all 0.0.0.0/0 trust" >> "$PG_HBA"
#     fi

#     # Wait for systemd to be up, then restart PostgreSQL to pick up listen_addresses
#     while ! systemctl is-system-running 2>/dev/null | grep -qE "running|degraded"; do sleep 2; done
#     systemctl restart postgresql@14-main 2>/dev/null || systemctl restart postgresql 2>/dev/null || true

#     log "PostgreSQL: exposed on port 5432"
# ) &

# Start systemd
log "Starting systemd init"
exec /sbin/init
