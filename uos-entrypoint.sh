#!/bin/bash

log() {
    echo "[uos-entrypoint][$(date -Iseconds)] $*"
}

set_unifi_property() {
    local key="$1" value="$2"
    local escaped_value="${value//\\/\\\\}"
    escaped_value="${escaped_value//&/\\&}"
    if grep -q "^${key}=" "$UNIFI_SYSTEM_PROPERTIES" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${escaped_value}|" "$UNIFI_SYSTEM_PROPERTIES"
    else
        echo "${key}=${value}" >> "$UNIFI_SYSTEM_PROPERTIES"
    fi
}


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
log "Setting PRODUCT_NAME to $PRODUCT_NAME"
echo "$PRODUCT_NAME" > /usr/lib/product_name

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

# Set UOS_SYSTEM_IP (required)
if [ -z "${UOS_SYSTEM_IP}" ]; then
    log "ERROR: UOS_SYSTEM_IP is required but not set"
    exit 1
fi
UNIFI_SYSTEM_PROPERTIES="/var/lib/unifi/system.properties"


set_unifi_property "system_ip" "$UOS_SYSTEM_IP"

# MONGO_INTERNAL=true  → keep the internal mongod that ships with UOS
# MONGO_INTERNAL=false → use an external MongoDB (default, removes internal mongod)
MONGO_INTERNAL="${MONGO_INTERNAL:-false}"

if [ "$MONGO_INTERNAL" = "false" ]; then
    MONGO_HOST="${MONGO_HOST:-unifi-os-server-mongodb}"
    MONGO_PORT="${MONGO_PORT:-27017}"
    MONGO_USER="${MONGO_USER:-}"
    MONGO_PASS="${MONGO_PASS:-}"
    MONGO_TLS="${MONGO_TLS:-false}"
    MONGO_AUTH_SOURCE="${MONGO_AUTH_SOURCE-admin}"

    if [ -n "${MONGO_USER}" ] && [ -n "${MONGO_PASS}" ]; then
        MONGO_URI="mongodb\\://${MONGO_USER}\\:${MONGO_PASS}@${MONGO_HOST}\\:${MONGO_PORT}"
    else
        MONGO_URI="mongodb\\://${MONGO_HOST}\\:${MONGO_PORT}"
    fi

    MONGO_PARAMS="tls\\=${MONGO_TLS}"
    if [ -n "${MONGO_USER}" ] && [ -n "${MONGO_AUTH_SOURCE}" ]; then
        MONGO_PARAMS="${MONGO_PARAMS}&authSource\\=${MONGO_AUTH_SOURCE}"
    fi

    log "External MongoDB: ${MONGO_HOST}:${MONGO_PORT}"
    set_unifi_property "db.mongo.local" "false"
    set_unifi_property "db.mongo.uri" "${MONGO_URI}/ace?${MONGO_PARAMS}"
    set_unifi_property "statdb.mongo.uri" "${MONGO_URI}/ace_stat?${MONGO_PARAMS}"

    if [ -f "/usr/bin/mongod" ]; then
        log "Removing internal mongod binary"
        rm -f /usr/bin/mongod
    fi
else
    log "Using internal MongoDB"
    set_unifi_property "db.mongo.local" "true"
    set_unifi_property "db.mongo.uri" "mongodb\\://localhost\\:27017/ace"
    set_unifi_property "statdb.mongo.uri" "mongodb\\://localhost\\:27017/ace_stat"
fi

# EXPOSE_NETWORK_APP=true → inject nginx bypass on port 7443 directly to the
# Network Application (port 8081), skipping UOS SSO.  Patched into the
# unifi-core pre-start hook so it survives the directory wipe on every restart.
EXPOSE_NETWORK_APP="${EXPOSE_NETWORK_APP:-false}"

if [ "$EXPOSE_NETWORK_APP" = "true" ]; then
    PRE_START="/usr/share/unifi-core/app/hooks/pre-start"
    INJECT='cp /root/site-localhost-bypass.conf /data/unifi-core/config/http/site-localhost-bypass.conf'
    if ! grep -qF "$INJECT" "$PRE_START" 2>/dev/null; then
        echo "$INJECT" >> "$PRE_START"
        log "Network App bypass: patched into $PRE_START"
    fi
fi

# Expose PostgreSQL on all interfaces so Docker port mapping can reach it.
# listen_addresses requires a restart (reload is not enough).
(
    PG_CONF="/etc/postgresql/14/main/postgresql.conf"
    PG_HBA="/etc/postgresql/14/main/pg_hba.conf"

    log "PostgreSQL exposure worker started"
    while [ ! -f "$PG_CONF" ]; do sleep 5; done

    if grep -q "^#\?listen_addresses" "$PG_CONF"; then
        sed -i "s/^#\?listen_addresses.*/listen_addresses = '*' /" "$PG_CONF"
    else
        echo "listen_addresses = '*'" >> "$PG_CONF"
    fi

    if ! grep -q "^host all all 0.0.0.0/0" "$PG_HBA" 2>/dev/null; then
        echo "host all all 0.0.0.0/0 trust" >> "$PG_HBA"
    fi

    # Wait for systemd to be up, then restart PostgreSQL to pick up listen_addresses
    while ! systemctl is-system-running 2>/dev/null | grep -qE "running|degraded"; do sleep 2; done
    systemctl restart postgresql@14-main 2>/dev/null || systemctl restart postgresql 2>/dev/null || true

    log "PostgreSQL: exposed on port 5432"
) &

# Forward journalctl to Docker log stream.
# Save Docker's stdout before systemd replaces it with /dev/null.
exec 3>&1
(
    # Wait until systemd-journald has created its journal files.
    # journalctl exits 0 even without files, so check its output instead.
    while journalctl -n 0 2>&1 | grep -q "No journal files were found"; do
        sleep 1
    done
    exec journalctl -f --no-hostname -o short >&3 2>&3
) &

# Start systemd
log "Starting systemd init"
exec /sbin/init
