#!/usr/bin/env bash
set -euo pipefail

# Idempotent hardening script for 8-16 GB Linux client agent VMs (Ubuntu/Debian).
# Provider-agnostic: works on any VPS/VDS or bare-metal Linux host. Run as root (or via sudo).

ADMIN_USER="ops"
PUBKEY_FILE=""
GATEWAY_MODE="polling" # polling (no 80/443) | webhook (opens 80/443)
SSH_ALLOW_CIDR=""      # optional IP/CIDR to restrict port 22 in UFW
SWAP_SIZE="2G"

usage() {
  cat <<'EOF'
Usage: harden-agent-vps.sh [options]
  --admin-user NAME       Non-root SSH admin user (default: ops)
  --pubkey-file PATH      Authorized SSH public key file for admin user (required if user has none)
  --mode polling|webhook  polling keeps 80/443 closed; webhook opens 80/443 (default: polling)
  --ssh-allow-cidr CIDR   Restrict UFW port 22 to CIDR (recommended; else allows 22/tcp)
  --swap-size SIZE        Swapfile size e.g. 2G or 4G (default: 2G)
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --admin-user) ADMIN_USER="$2"; shift 2 ;;
    --pubkey-file) PUBKEY_FILE="$2"; shift 2 ;;
    --mode) GATEWAY_MODE="$2"; shift 2 ;;
    --ssh-allow-cidr) SSH_ALLOW_CIDR="$2"; shift 2 ;;
    --swap-size) SWAP_SIZE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root." >&2
  exit 1
fi

if [ "$GATEWAY_MODE" != "polling" ] && [ "$GATEWAY_MODE" != "webhook" ]; then
  echo "--mode must be polling or webhook" >&2
  exit 2
fi

echo "[1/8] Installing baseline security packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ufw fail2ban unattended-upgrades apt-listchanges acl rkhunter

echo "[2/8] Configuring swap (${SWAP_SIZE}) and kernel sysctl..."
if [ ! -f /swapfile ]; then
  fallocate -l "$SWAP_SIZE" /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

cat > /etc/sysctl.d/99-agent-vps.conf <<'EOF'
vm.swappiness = 10
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
EOF
sysctl --system >/dev/null

echo "[3/8] Setting up non-root admin user (${ADMIN_USER}) and SSH hardening..."
if ! id "$ADMIN_USER" >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash --groups sudo "$ADMIN_USER"
  passwd -l "$ADMIN_USER" >/dev/null
fi
install -d -m 0700 -o "$ADMIN_USER" -g "$ADMIN_USER" "/home/${ADMIN_USER}/.ssh"
if [ -n "$PUBKEY_FILE" ]; then
  if [ ! -s "$PUBKEY_FILE" ]; then
    echo "Pubkey file missing or empty: $PUBKEY_FILE" >&2
    exit 1
  fi
  install -m 0600 -o "$ADMIN_USER" -g "$ADMIN_USER" "$PUBKEY_FILE" "/home/${ADMIN_USER}/.ssh/authorized_keys"
elif [ ! -s "/home/${ADMIN_USER}/.ssh/authorized_keys" ]; then
  echo "ERROR: ${ADMIN_USER} has no authorized_keys; pass --pubkey-file before disabling root/passwords." >&2
  exit 1
fi

# Lock root password (neutralizes UI-provisioned initial root passwords)
passwd -l root >/dev/null || true

cat > /etc/ssh/sshd_config.d/99-hardening.conf <<EOF
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
PubkeyAuthentication yes
AllowUsers ${ADMIN_USER}
X11Forwarding no
AllowAgentForwarding no
MaxAuthTries 4
EOF
sshd -t
systemctl reload ssh || systemctl reload sshd

echo "[4/8] Creating isolated svc-agent user and /var/lib/hermes-agent..."
if ! id svc-agent >/dev/null 2>&1; then
  useradd --system --create-home --home-dir /var/lib/hermes-agent --shell /usr/sbin/nologin svc-agent
fi
install -d -m 0700 -o svc-agent -g svc-agent /var/lib/hermes-agent /var/lib/hermes-agent/workspace

echo "[5/8] Hardening /dev/shm mount flags (noexec,nosuid,nodev)..."
if mountpoint -q /dev/shm; then
  mount -o remount,noexec,nosuid,nodev /dev/shm || true
  if ! grep -qE '^tmpfs\s+/dev/shm\s' /etc/fstab; then
    echo 'tmpfs /dev/shm tmpfs defaults,noexec,nosuid,nodev 0 0' >> /etc/fstab
  fi
fi

echo "[6/8] Disabling unneeded local daemons..."
systemctl disable --now avahi-daemon.service avahi-daemon.socket cups.service cups.socket cups.path cups-browsed.service 2>/dev/null || true

echo "[7/8] Configuring UFW inbound + outbound anti-abuse rules..."
ufw default deny incoming
ufw default allow outgoing

if [ -n "$SSH_ALLOW_CIDR" ]; then
  ufw allow from "$SSH_ALLOW_CIDR" to any port 22 proto tcp comment 'admin-ssh'
else
  ufw allow 22/tcp comment 'ssh-restrict-in-cloud-firewall'
fi

if [ "$GATEWAY_MODE" = "webhook" ]; then
  ufw allow 80/tcp comment 'http'
  ufw allow 443/tcp comment 'https'
fi

# Block outbound SMTP spam & common Stratum cryptominer pool ports
for p in 25 465 587 3333 4444 5555 7777 8888 9999 14433 14444 45700; do
  ufw deny out "${p}/tcp" comment 'anti-abuse-egress'
done

ufw --force enable

echo "[8/8] Enabling fail2ban and unattended-upgrades..."
cat > /etc/fail2ban/jail.d/sshd-local.conf <<'EOF'
[DEFAULT]
banaction = ufw
bantime = 1h
findtime = 10m
maxretry = 4

[sshd]
enabled = true
EOF

cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

systemctl enable --now fail2ban unattended-upgrades
systemctl restart fail2ban

echo "Done. Verify login as '${ADMIN_USER}' in a NEW terminal before closing this session."
