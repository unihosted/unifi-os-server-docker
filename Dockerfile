# The workflow loads the extracted base image as: uosserver:base
FROM uosserver:base

ARG UOS_SERVER_VERSION
ARG FIRMWARE_PLATFORM

# Optional: expose these as env so your entrypoint / runtime can use them
ENV UOS_SERVER_VERSION="${UOS_SERVER_VERSION}"
ENV FIRMWARE_PLATFORM="${FIRMWARE_PLATFORM}"

# Copy your entrypoint script into the image
COPY uos-entrypoint.sh /root/uos-entrypoint.sh

# Make sure it's executable
RUN chmod +x /root/uos-entrypoint.sh

# If your entrypoint expects bash, this is usually safe
ENTRYPOINT ["/root/uos-entrypoint.sh"]