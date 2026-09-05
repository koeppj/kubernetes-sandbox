FROM debian:12.11-slim

# Debian 12 pins the Postfix runtime used by this component.
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        postfix=3.7.11-0+deb12u1 \
    && rm -rf /var/lib/apt/lists/*

# The recipient map is mounted at /etc/postfix/recipient-map/virtual. Keep
# smtpd outside Postfix's queue-directory chroot so it can read that map while
# evaluating reject_unlisted_recipient. The outbound smtp client also needs
# Kubernetes' resolver configuration, which is not present in that chroot.
RUN postconf -M "smtp/inet=smtp inet n - n - - smtpd" \
    && postconf -M "smtp/unix=smtp unix - - n - - smtp"

COPY image/entrypoint.sh /usr/local/bin/postfix-entrypoint

RUN chmod 0755 /usr/local/bin/postfix-entrypoint

EXPOSE 25
ENTRYPOINT ["/usr/local/bin/postfix-entrypoint"]
