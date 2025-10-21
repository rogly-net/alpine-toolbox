FROM alpine:latest

# Install required packages
RUN apk add --no-cache \
    bash \
    shadow \
    dcron \
    su-exec \
    tzdata \
    && rm -rf /var/cache/apk/*

# Copy entrypoint script
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Set default environment variables
# - Defaults to root (PUID/PGID=0). Non-root users are created at runtime by the entrypoint.
ENV PUID=0
ENV PGID=0
ENV TZ=UTC

# Users are handled at runtime by the entrypoint (no build-time user creation)

# Set the entrypoint
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

# Default shell (can be overridden)
CMD ["sh"]
