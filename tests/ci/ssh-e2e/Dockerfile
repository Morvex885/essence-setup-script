FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends openssh-server ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --shell /bin/sh e2e \
    && echo 'e2e:essence-e2e-password' | chpasswd \
    && mkdir -p /run/sshd /home/e2e/.ssh \
    && chown -R e2e:e2e /home/e2e/.ssh \
    && chmod 700 /home/e2e/.ssh
COPY sshd_config /etc/ssh/sshd_config_e2e
COPY entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/bin/sh", "/entrypoint.sh"]
