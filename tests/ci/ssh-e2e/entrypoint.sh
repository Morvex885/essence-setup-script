#!/bin/sh
set -eu
cp /fixture/client_key.pub /home/e2e/.ssh/authorized_keys
chown e2e:e2e /home/e2e/.ssh/authorized_keys
chmod 600 /home/e2e/.ssh/authorized_keys
exec /usr/sbin/sshd -D -e -f /etc/ssh/sshd_config_e2e
