ARG BUILD_FROM
FROM $BUILD_FROM

# ============================================================
#  Connect Nest Add-on Dockerfile
#  Base image is provided by HA Supervisor (Alpine Linux based)
#  BUILD_FROM is set automatically per architecture by Supervisor
# ============================================================

# Install nginx and required tools
RUN apk add --no-cache \
    nginx \
    curl \
    bash \
    jq

# Create required directories
RUN mkdir -p \
    /var/log/nginx \
    /var/lib/nginx/tmp \
    /usr/share/nginx/cn-override/static/icons \
    /etc/nginx/conf.d \
    /run/nginx

# Copy Connect Nest branded override files
COPY rootfs/usr/share/nginx/cn-override/ /usr/share/nginx/cn-override/

# Copy startup script
COPY run.sh /run.sh
RUN chmod +x /run.sh

# Labels required by HA Supervisor
ARG BUILD_ARCH
ARG BUILD_DATE
ARG BUILD_DESCRIPTION
ARG BUILD_NAME
ARG BUILD_REF
ARG BUILD_REPOSITORY
ARG BUILD_VERSION

LABEL \
    io.hass.name="${BUILD_NAME}" \
    io.hass.description="${BUILD_DESCRIPTION}" \
    io.hass.arch="${BUILD_ARCH}" \
    io.hass.type="addon" \
    io.hass.version=${BUILD_VERSION} \
    maintainer="roarbis <https://github.com/roarbis>" \
    org.opencontainers.image.title="${BUILD_NAME}" \
    org.opencontainers.image.description="${BUILD_DESCRIPTION}" \
    org.opencontainers.image.source="https://github.com/roarbis/CN-Addon" \
    org.opencontainers.image.created=${BUILD_DATE} \
    org.opencontainers.image.revision=${BUILD_REF} \
    org.opencontainers.image.version=${BUILD_VERSION}

CMD [ "/run.sh" ]
