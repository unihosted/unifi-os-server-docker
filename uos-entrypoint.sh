#!/bin/bash

# Persist UOS_UUID env var
if [ ! -f /data/uos_uuid ]; then
    if [ -n "${UOS_UUID+1}" ]; then
        echo "Setting UUID to $UOS_UUID"
        echo "$UOS_UUID" > /data/uos_uuid
    else
        echo "No UUID present, generating..."
        UUID=$(cat /proc/sys/kernel/random/uuid)

        # Spoof a v5 UUID
        UOS_UUID=$(echo $UUID | sed s/./5/15)
        echo "Setting UUID to $UOS_UUID"
        echo "$UOS_UUID" > /data/uos_uuid
    fi
fi

# Read version from package.json and write version string
echo "Setting UOS_SERVER_VERSION to $UOS_SERVER_VERSION"
echo "UOSSERVER.0000000.$UOS_SERVER_VERSION.0000000.000000.0000" > /usr/lib/version
echo "Setting FIRMWARE_PLATFORM to $FIRMWARE_PLATFORM"
echo "$FIRMWARE_PLATFORM" > /usr/lib/platform

# Create eth0 alias to tap0 (requires NET_ADMIN cap & macvlan kernel module loaded on host) 
if [ ! -d "/sys/devices/virtual/net/eth0" ] && [ -d "/sys/devices/virtual/net/tap0" ]; then
    ip link add name eth0 link tap0 type macvlan
    ip link set eth0 up
fi 

# Initialize nginx log dirs
NXINX_LOG_DIR="/var/log/nginx"
if [ ! -d "$NXINX_LOG_DIR" ]; then
    mkdir -p "$NXINX_LOG_DIR"
    chown nginx:nginx "$NXINX_LOG_DIR"
    chmod 755 "$NXINX_LOG_DIR"
fi

# Initialize mongodb log dirs
MONGODB_LOG_DIR="/var/log/mongodb"
if [ ! -d "$MONGODB_LOG_DIR" ]; then
    mkdir -p "$MONGODB_LOG_DIR"
    chown mongodb:mongodb "$MONGODB_LOG_DIR"
    chmod 755 "$MONGODB_LOG_DIR"
fi

# Initialize mongodb lib dirs
MONGODB_LIB_DIR="/var/lib/mongodb"
chown -R mongodb:mongodb "$MONGODB_LIB_DIR"

# Initialize rabbitmq log dirs
RABBITMQ_LOG_DIR="/var/log/rabbitmq"
if [ ! -d "$RABBITMQ_LOG_DIR" ]; then
    mkdir -p "$RABBITMQ_LOG_DIR"
    chown rabbitmq:rabbitmq "$RABBITMQ_LOG_DIR"
    chmod 755 "$RABBITMQ_LOG_DIR"
fi

# Apply Synology patches
SYS_VENDOR="/sys/class/dmi/id/sys_vendor"
if [ -f "$SYS_VENDOR" ] && grep -q "Synology Inc." "$SYS_VENDOR"; then
    echo "Synology hardware found, applying patches..."

    # Set Postgres overrides
    mkdir -p /etc/systemd/system/postgresql@14-main.service.d
    {
        echo "[Service]"
        echo "PIDFile="
    } > /etc/systemd/system/postgresql@14-main.service.d/override.conf

    # Set RabbitMQ overrides
    mkdir -p /etc/systemd/system/rabbitmq-server.service.d
    {
        echo "[Service]"
        echo "Type=simple"
    } > /etc/systemd/system/rabbitmq-server.service.d/override.conf

    # Set ulp-go overrides
    mkdir -p /etc/systemd/system/ulp-go.service.d
    {
        echo "[Service]"
        echo "Type=simple"
    } > /etc/systemd/system/ulp-go.service.d/override.conf

    echo "Synology patches applied!"
fi

# Set UOS_SYSTEM_IP (required)
if [ -z "${UOS_SYSTEM_IP}" ]; then
    echo "ERROR: UOS_SYSTEM_IP is required but not set"
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

set_property "system_ip" "$UOS_SYSTEM_IP"
set_property "db.mongo.local" "false"
set_property "db.mongo.uri" 'mongodb\://root\:root@unifi-network-mongodb\:27017/ace?tls\=false&authSource\=admin'
set_property "statdb.mongo.uri" 'mongodb\://root\:root@unifi-network-mongodb\:27017/ace_stat?tls\=false&authSource\=admin'



# Remove the duplicate mongo server /usr/bin/mongod
if [ -f "/usr/bin/mongod" ]; then
    rm -f /usr/bin/mongod
fi




# Start systemd
exec /sbin/init