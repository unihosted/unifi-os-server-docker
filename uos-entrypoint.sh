#!/bin/bash


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log() {
    echo "[uos-entrypoint][$(date -Iseconds)] $*"
}

# Set or update a key in UniFi's system.properties (creates the file if absent).
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

# Remove a key from system.properties (no-op if the key or file is absent).
remove_unifi_property() {
    local key="$1"
    sed -i "/^${key}=/d" "$UNIFI_SYSTEM_PROPERTIES" 2>/dev/null
}

# Create a directory owned by a given user:group if it doesn't already exist.
ensure_dir() {
    local dir="$1" owner="$2"
    if [ ! -d "$dir" ]; then
        log "Initializing $dir"
        mkdir -p "$dir"
        chown "$owner" "$dir"
        chmod 755 "$dir"
    fi
}

# ---------------------------------------------------------------------------
# 1. UUID
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# 2. Version / platform / product metadata
# ---------------------------------------------------------------------------

ARCH="$(dpkg --print-architecture)"
case "$ARCH" in
    amd64)
        FIRMWARE_PLATFORM="linux-x64"
        ;;
    arm64)
        FIRMWARE_PLATFORM="arm64"
        ;;
    *)
        log "ERROR: FIRMWARE_PLATFORM not found for $ARCH"
        exit 1
        ;;
esac

log "Setting FIRMWARE_PLATFORM to $FIRMWARE_PLATFORM"
log "Setting PRODUCT_NAME to $PRODUCT_NAME"
log "Setting APP_MODEL to $APP_MODEL"
log "Setting APP_VERSION to $APP_VERSION"

echo "$FIRMWARE_PLATFORM" > /usr/lib/platform
echo "$PRODUCT_NAME" > /usr/lib/product_name
echo "$APP_MODEL" > /usr/lib/app_model

# Protect Server mounts /usr/lib/version itself.
if [ "$APP_MODEL" != "PROTECT_SERVER" ]; then
    echo "$APP_MODEL.0000000.$APP_VERSION.0000000.000000.0000" > /usr/lib/version
fi

# ---------------------------------------------------------------------------
# 3. Networking — eth0 macvlan alias
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# 4. Service log & data directories
# ---------------------------------------------------------------------------

ensure_dir "/var/log/nginx"     "nginx:nginx"
ensure_dir "/var/log/mongodb"   "mongodb:mongodb"
ensure_dir "/var/log/rabbitmq"  "rabbitmq:rabbitmq"

# MongoDB data dir — always chown (data may have been volume-mounted)
log "Ensuring mongodb ownership for /var/lib/mongodb"
chown -R mongodb:mongodb /var/lib/mongodb

# ---------------------------------------------------------------------------
# 5. MongoDB — internal vs. external
# ---------------------------------------------------------------------------

# UOS_SYSTEM_IP is required for UniFi to function.
if [ -z "${UOS_SYSTEM_IP}" ]; then
    log "ERROR: UOS_SYSTEM_IP is required but not set"
    exit 1
fi
UNIFI_SYSTEM_PROPERTIES="/var/lib/unifi/system.properties"
set_unifi_property "system_ip" "$UOS_SYSTEM_IP"

# MONGO_INTERNAL=true  → let the UniFi Network App manage its own mongod
#                       (port 27117, dbpath /usr/lib/unifi/data/db)
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
    log "Using internal MongoDB (managed by UniFi Network App)"
    set_unifi_property "db.mongo.local" "true"
    # Remove any stale external URIs so the app falls back to its
    # internal default (port 27117) instead of trying to connect to
    # a non-existent external instance.
    remove_unifi_property "db.mongo.uri"
    remove_unifi_property "statdb.mongo.uri"

    # The app starts its own mongod on port 27117, so disable the
    # system mongodb.service to avoid an unnecessary start/stop cycle.
    rm -f /etc/systemd/system/multi-user.target.wants/mongodb.service
fi

# ---------------------------------------------------------------------------
# 6. Network App bypass (port 7443)
# ---------------------------------------------------------------------------
#
# By default the UniFi Network Application is fronted by UOS SSO — you must
# authenticate through the UniFi OS Console before reaching the controller UI
# or its REST API.  This makes automation and direct API access difficult.
#
# When EXPOSE_NETWORK_APP=true an nginx server block is injected that listens
# on port 7443 and proxies directly to the Network App on 127.0.0.1:8081,
# skipping SSO entirely.  UniHosted uses this for debugging and to call the
# original UniFi Network API without going through the UOS SSO layer.
#
#   *** NOT FOR PRODUCTION — DO NOT EXPOSE PUBLICLY ***
#
# This bypass circumvents SSO authentication.  It must only be bound to
# localhost (the docker-compose.yaml maps it as 127.0.0.1:7443:7443) and
# never published to a public interface.  Exposing it to the network would
# allow unauthenticated access to the Network Application.
#
# The injection is patched into unifi-core's pre-start hook so it survives
# the config directory wipe that happens on every restart.

EXPOSE_NETWORK_APP="${EXPOSE_NETWORK_APP:-false}"

if [ "$EXPOSE_NETWORK_APP" = "true" ]; then
    PRE_START="/usr/share/unifi-core/app/hooks/pre-start"
    INJECT='cp /root/site-localhost-bypass.conf /data/unifi-core/config/http/site-localhost-bypass.conf'
    if ! grep -qF "$INJECT" "$PRE_START" 2>/dev/null; then
        echo "$INJECT" >> "$PRE_START"
        log "Network App bypass: patched into $PRE_START"
    fi
fi

# ---------------------------------------------------------------------------
# 7. PostgreSQL — expose on all interfaces for Docker port mapping
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# 8. Journal forwarding & systemd
# ---------------------------------------------------------------------------

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

log "Starting systemd init"

exec /sbin/init
