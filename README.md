# 🛡️ Linux VPS Hardening (Contabo & Agent Gateways)

Want to deploy client AI agents on 8-16 GB Contabo VMs without forcing clients onto Tailscale or leaving servers open to brute-force attacks and cryptominers?

**Linux VPS Hardening packs a reusable Hermes skill, first-boot templates, and host-audit scripts into one repeatable setup.** Provision a single-tenant client VM, isolate the agent gateway under a locked-down non-root service account, and verify firewall, SSH, and anti-malware controls before handing it over.

## ✨ What's included

- **🔑 Key-only SSH and edge lockdowns:** Disables password authentication and root password logins, clears Contabo UI-ordered plaintext root passwords, and pairs Contabo's Cloud Firewall with `ufw` and `fail2ban`.
- **🌐 No forced client Tailscale:** Keeps admin access on your own plane (static bastion IP, operator-only WireGuard/Tailscale, or Contabo VNC console) while clients interact purely through Telegram, Slack, Discord, or an authenticated web UI.
- **🛡️ Non-root gateway containment:** Runs Hermes gateways as `svc-agent` under `/var/lib/hermes-agent` (`0700`) with `NoNewPrivileges=true`, `ProtectSystem=strict`, `ProtectHome=yes`, `PrivateTmp=true`, and 8-16 GB cgroup caps.
- **⛏️ Anti-cryptominer and abuse defense:** Mounts `/dev/shm` with `noexec,nosuid,nodev`, blocks outbound SMTP (`25/465/587`) and common Stratum mining ports, disables runtime lazy installs, and shuts off `avahi`/`cups`.
- **🔍 Read-only malware and drift audit:** `check-miner-malware.sh` inspects firewall/SSH state, `0.0.0.0` listeners, high-CPU or `/tmp` processes, deleted executables, crontabs, `.env` permissions, and `hermes doctor` advisories.
- **📦 Contabo 8-16 GB sizing:** Configures swap (`2G`/`4G`) and `MemoryMax`/`CPUQuota` limits so headless browsers or agent loops never starve SSH or trigger surprise OOM kills.

## 📦 Templates, scripts, and references

Each file serves a single stage of provisioning, hardening, or auditing a client VM.

| Artifact | Type | Purpose | Path |
| --- | --- | --- | --- |
| Skill playbook | Hermes `SKILL.md` | Step-by-step workflow, pitfalls, and verification | [`SKILL.md`](SKILL.md) |
| Client VPS guide | Reference | Contabo 8-16 GB sizing, no-Tailscale access, Cloud Firewall, `restic` backups | [`references/contabo-client-vps.md`](references/contabo-client-vps.md) |
| Gateway & malware guide | Reference | Hermes `config.yaml`, `security_policy.yaml`, SSRF, and supply-chain rules | [`references/agent-gateway-and-malware-defense.md`](references/agent-gateway-and-malware-defense.md) |
| First-boot config | Cloud-init YAML | Automated Ubuntu 24.04 setup for Contabo API `userData` | [`templates/cloud-init-contabo.yaml`](templates/cloud-init-contabo.yaml) |
| Gateway unit | Systemd template | Hardened `svc-agent` service with 8-16 GB RAM/CPU limits | [`templates/hermes-gateway.service`](templates/hermes-gateway.service) |
| Host hardening | Bash script | Idempotent OS, firewall, swap, SSH, and anti-abuse setup | [`scripts/harden-contabo-agent.sh`](scripts/harden-contabo-agent.sh) |
| Security audit | Bash script | Read-only check for miners, listeners, persistence, and `.env` leaks | [`scripts/check-miner-malware.sh`](scripts/check-miner-malware.sh) |

### Host & gateway scope

The skill targets Ubuntu 24.04/22.04 and Debian Linux VPS hosts running one client per VM. In `--mode polling` (default for Telegram polling, Slack Socket Mode, or Discord gateways), `harden-contabo-agent.sh` keeps ports `80` and `443` closed completely; `--mode webhook` opens `80/tcp` and `443/tcp` for Nginx reverse proxies.

Multi-tenant co-hosting, DNS propagation, and billing/account setup on the Contabo Customer Panel remain outside the scripts and are covered as operational checks in the reference docs.

## 🚀 Quick start

You need [Hermes Agent](https://hermes-agent.nousresearch.com/docs) and a fresh or existing Ubuntu/Debian Contabo VPS (8-16 GB RAM) with `root` or `sudo` access and your SSH public key.

```bash
# Install the skill directly from GitHub
hermes skills install dadhalfdev/skill-linux-vps-hardening --category devops

# Harden a fresh or UI-ordered Contabo VM (polling gateway: keeps 80/443 closed)
sudo bash scripts/harden-contabo-agent.sh \
  --admin-user ops \
  --pubkey-file /root/.ssh/authorized_keys \
  --mode polling \
  --ssh-allow-cidr YOUR.STATIC.IP/32

# Run the read-only security and cryptominer audit
sudo bash scripts/check-miner-malware.sh --verify
```

Review `scripts/harden-contabo-agent.sh` and confirm you can log in as `--admin-user` in a new SSH session before closing your initial root shell. When ordering through Contabo's API, pass `templates/cloud-init-contabo.yaml` (with `REPLACE_ADMIN_USER` and `REPLACE_SSH_PUBLIC_KEY` substituted) in `userData` instead of waiting for post-boot login.

## 📝 System writes and service hardening

Running `scripts/harden-contabo-agent.sh` or booting with `templates/cloud-init-contabo.yaml` modifies host OS configuration as follows:

- **Swap & kernel (`sysctl`):** Creates `/swapfile` (default `2G`), appends it to `/etc/fstab`, and writes `/etc/sysctl.d/99-agent-vps.conf` (`vm.swappiness=10`, `rp_filter=1`, `tcp_syncookies=1`, disables ICMP redirects).
- **SSH & admin users:** Creates the non-root sudo user (default `ops`), installs `authorized_keys` (`0600`), locks the `root` password (`passwd -l root`), writes `/etc/ssh/sshd_config.d/99-hardening.conf` (`PasswordAuthentication no`, `PermitRootLogin no`, `AllowUsers`, `X11Forwarding no`, `AllowAgentForwarding no`), validates with `sshd -t`, and reloads `ssh`.
- **Service account & mounts:** Creates system user `svc-agent` (`/usr/sbin/nologin`) with `/var/lib/hermes-agent` (`0700`), remounts `/dev/shm` with `noexec,nosuid,nodev` (persisted to `/etc/fstab`), and disables `avahi-daemon` and `cups`.
- **Firewall, bans & patching:** Configures `ufw` (`default deny incoming`, `default allow outgoing`, outbound denies on SMTP `25/465/587` and Stratum ports `3333/4444/5555/7777/8888/9999/14433/14444/45700`), writes `/etc/fail2ban/jail.d/sshd-local.conf`, and enables `unattended-upgrades` via `/etc/apt/apt.conf.d/20auto-upgrades`.

`scripts/check-miner-malware.sh` is **strictly read-only**: it inspects firewall/SSH state, sockets, running processes, `/proc/*/exe` targets, crontabs, `.env` permissions, and `hermes doctor` output without modifying files or killing processes.

## 💳 Infrastructure & operational notes

- **Contabo Cloud Firewall:** Available at no extra charge on Contabo VPS/VDS instances and filters **inbound** traffic in front of the VM; OS-level `ufw` rules remain necessary for outbound anti-abuse blocks.
- **8 GB vs. 16 GB tuning:** `templates/hermes-gateway.service` defaults to `MemoryHigh=4G` / `MemoryMax=5G` for 8 GB VMs; raise to `MemoryMax=11G` on 16 GB VMs, or use `--swap-size 4G` when running headless browsers or Docker containers.
- **API spend caps:** Hardening the OS does not cap LLM provider billing—always configure monthly spend limits on client OpenRouter/OpenAI/Anthropic keys.

## 🔄 Common workflows

```bash
# 1. Harden a VM that serves an Nginx webhook or web UI on 80/443
sudo bash scripts/harden-contabo-agent.sh \
  --admin-user ops \
  --pubkey-file ~/.ssh/id_ed25519.pub \
  --mode webhook \
  --swap-size 4G

# 2. Deploy the isolated systemd unit for Hermes gateway
sudo install -m 0644 templates/hermes-gateway.service /etc/systemd/system/hermes-gateway.service
sudo systemctl daemon-reload
sudo systemctl enable --now hermes-gateway

# 3. Run an ad-hoc audit (exit non-zero on failure with --verify)
sudo bash scripts/check-miner-malware.sh --verify
```

For Hermes config (`approvals.deny`, `security.allow_private_urls: false`, `security.allow_lazy_installs: false`, and `security_policy.yaml`), see [`references/agent-gateway-and-malware-defense.md`](references/agent-gateway-and-malware-defense.md).

## 🔐 Security boundaries and disclosure

- **Network activity:** `harden-contabo-agent.sh` only contacts your OS APT mirrors via `apt-get update` / `apt-get install` (`ufw`, `fail2ban`, `unattended-upgrades`, `apt-listchanges`, `acl`, `rkhunter`). Neither script phones home, sends telemetry, or opens outbound connections on its own.
- **Privilege requirements:** `harden-contabo-agent.sh` requires `root` (`sudo`) to configure system users, SSH, `ufw`, `sysctl`, and `systemd`. `check-miner-malware.sh` runs read-only checks (root recommended so it can inspect `/var/spool/cron/crontabs` and `/proc/*/exe` across all users).
- **What host hardening does NOT solve alone:** Non-root `svc-agent` and `ProtectSystem=strict` protect the host OS, **not** `/var/lib/hermes-agent` itself. If an agent with `terminal` or `execute_code` enabled processes untrusted external content (emails, web pages, public group chats), a prompt injection can still read `/var/lib/hermes-agent/.env` and exfiltrate secrets over outbound HTTPS (`443`). For untrusted-input agents, run `terminal.backend: docker` (no host `.env` mount), disable `terminal`, or enforce `approvals.mode: manual`.
- **Account and backup hygiene:** Enforce 2FA on the client's Contabo Customer Panel and messaging accounts, and schedule automated off-box `restic` backups rather than relying solely on VPS snapshots.
