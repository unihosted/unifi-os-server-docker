FROM ghcr.io/dockette/debian:stretch

# Prevent interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install dependencies
RUN apt-get update && apt-get install -y \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    systemd \
    systemd-sysv \
    && rm -rf /var/lib/apt/lists/*

# Add UniFi repository
RUN curl -fsSL https://dl.ui.com/unifi/debian/alpha/GPG-KEY-ubnt-alpha | apt-key add - && \
    echo "deb https://dl.ui.com/unifi/debian/alpha stretch main" > /etc/apt/sources.list.d/ubnt.list && \
    apt-get update

# Install UniFi OS (unifi-core) and dependencies
# Replace with the actual package version you need
RUN apt-get install -y \
    unifi-core \
    unifi-network-appliance \
    mongodb-server \
    postgresql-14 \
    rabbitmq-server \
    nginx \
    iproute2 \
    iptables \
    && rm -rf /var/lib/apt/lists/*

# Create required directories
RUN mkdir -p /data/unifi-core/config/http \
    /data/unifi-core/logs \
    /data/unifi-core/devices \
    /data/unifi-core/eeprom \
    /data/unifi-core/backups \
    /data/unifi-core/uploads \
    /data/unifi-core/cache \
    /data/unifi-core/database \
    /var/lib/unifi \
    /var/log/nginx \
    /var/log/mongodb \
    /var/log/rabbitmq \
    /var/lib/mongodb

# Inject localhost bypass into stock nginx template
# This makes it persistent across ucore restarts
COPY site-localhost-bypass.conf /usr/share/unifi-core/http/site-localhost-bypass.conf
RUN echo "" >> /usr/share/unifi-core/http/site-local-ip.conf && \
    echo "# Include localhost bypass (injected at build time)" >> /usr/share/unifi-core/http/site-local-ip.conf && \
    echo "include /usr/share/unifi-core/http/site-localhost-bypass.conf;" >> /usr/share/unifi-core/http/site-local-ip.conf

# Copy entrypoint script
COPY uos-entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Set up environment defaults
ENV UOS_SERVER_VERSION=5.0.126
ENV FIRMWARE_PLATFORM=UOSSERVER
ENV MONGO_HOST=unifi-os-server-mongodb
ENV MONGO_PORT=27017
ENV MONGO_USER=root
ENV MONGO_PASS=root
ENV MONGO_TLS=false
ENV MONGO_AUTH_SOURCE=admin

# Use systemd as init
ENTRYPOINT ["/entrypoint.sh"]
