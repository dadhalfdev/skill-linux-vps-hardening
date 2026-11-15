---
name: linux-vps-hardening
description: "Use when securing a Contabo VPS or client agent gateway."
version: 1.1.0
author: Hermes
license: MIT
platforms: [linux]
metadata:
  hermes:
    category: devops
    tags: [Security, VPS, Contabo, Gateway, Systemd, Hardening]
    related_skills: [hermes-multi-profile-setup, cron-shell-execution]
---

# Linux VPS & Client Agent Gateway Hardening

Provision, harden, and audit 8-16 GB Contabo VPS hosts running AI agent gateways and web apps without forcing clients onto Tailscale. Covers Contabo first-boot setup, non-root `systemd` containment, gateway allowlists, and anti-cryptominer/anti-malware controls; does not manage DNS propagation, billing, or multi-tenant co-hosting on a single kernel. Dependencies: Ubuntu/Debian Linux primitives (`ufw`, `fail2ban`, `systemd`, `unattended-upgrades`, `sshd`, `nginx`).

## When to Use

- Setting up a new 8-16 GB Contabo VM for a client AI agent gateway
- Securing a client VPS without requiring them to install Tailscale
- Auditing an existing multi-app VPS for cross-project `.env` leaks, root services, or `0.0.0.0` binds
- Checking a host for cryptominers, persistence backdoors, or supply-chain advisories

## Prerequisites

- Ubuntu 24.04/22.04 or Debian VPS (8-16 GB RAM, one client per VM)
- Root or `sudo` SSH access (or Contabo Customer Panel access) and your admin SSH public key
- Contabo Cloud Firewall access in the Customer Panel (free on VPS/VDS)
- Client messaging bot tokens and explicit allowed user IDs (never `GATEWAY_ALLOW_ALL_USERS=true`)

## How to Run

1. Load reference guides on demand via `skill_view`:
   - `references/contabo-client-vps.md` — 8-16 GB Contabo architecture, no-client-Tailscale access, Cloud Firewall, and backups
   - `references/agent-gateway-and-malware-defense.md` — Hermes gateway lockdown, anti-cryptominer rules, and malware audit
2. Inspect and customize `templates/cloud-init-contabo.yaml` and `templates/hermes-gateway.service` using `read_file` and `write_file`.
3. Copy `scripts/harden-contabo-agent.sh` and `scripts/check-miner-malware.sh` to the target host and invoke them through the `terminal` tool.

## Quick Reference

| Artifact | Purpose |
|---|---|
| `templates/cloud-init-contabo.yaml` | First-boot Contabo `userData` for 8-16 GB VMs (swap, UFW, SSH keys, fail2ban) |
| `templates/hermes-gateway.service` | Hardened `svc-agent` systemd unit with memory/CPU caps |
| `scripts/harden-contabo-agent.sh` | Idempotent OS + firewall + anti-miner hardening for fresh or UI-ordered VMs |
| `scripts/check-miner-malware.sh` | Read-only audit for miners, unauthorized listeners, persistence, and `hermes doctor` |
| `references/contabo-client-vps.md` | Contabo sizing, no-client-Tailscale admin patterns, and encrypted `restic` backups |
| `references/agent-gateway-and-malware-defense.md` | Gateway `config.yaml`, `security_policy.yaml`, SSRF, and supply-chain controls |

## Procedure

### 1. Audit an existing host before changing anything

Run a baseline check through `terminal` and inspect unit configs with `read_file`:

```bash
ufw status verbose
sshd -T | grep -Ei '^(passwordauthentication|permitrootlogin|pubkeyauthentication|allowusers|x11forwarding|allowagentforwarding)'
ss -tulpn
systemctl list-units --type=service --state=running --no-pager
ls -la /var/run/reboot-required
```

Check `getfacl -p` on parent directories of any non-root service, and check secret files with `search_files` / `stat` for `0644` permissions inside shared project folders.

### 2. Provision and harden an 8-16 GB Contabo client VM

1. **One client = one VPS.** Pass `templates/cloud-init-contabo.yaml` in Contabo `userData` (plus `sshKeys`) when ordering via API, or run `scripts/harden-contabo-agent.sh` immediately after a UI order (which emails a plaintext root password by default).
2. **Protect without forcing client Tailscale:**
   - Enable Contabo's free Cloud Firewall on the instance.
   - If you manage the VM and the client only uses Telegram/Slack/Discord or a web UI: allow only your operator IP (or your own admin-only WireGuard/Tailscale) on port 22, and open **zero** public ports for polling-only gateways (only `80/443` if serving webhooks or a web UI).
   - If the client self-manages: give them an authenticated web UI, keep SSH IP-allowlisted in Contabo Cloud Firewall (or disabled with Contabo Panel VNC console for break-glass). Never expose a browser shell (`ttyd`) behind email OTP.
3. **Run the host hardening script** via `terminal` (sets 2-4 GB swap for 8-16 GB RAM, `ufw` default-deny, outbound SMTP `25/465/587` and Stratum mining port blocks, `noexec,nosuid,nodev` on `/dev/shm` and `/var/tmp`, `fail2ban`, `unattended-upgrades`, disables `avahi`/`cups`, and creates `svc-agent`):

```bash
sudo bash scripts/harden-contabo-agent.sh --admin-user ops --pubkey-file /root/.ssh/authorized_keys --mode polling
```

### 3. Deploy and isolate the agent gateway

1. Host the agent profile under `/var/lib/hermes-agent` owned `0700` by `svc-agent` (never under `/root`, which breaks on `chmod 700`). Keep `.env` at `0600`.
2. Install `templates/hermes-gateway.service` (sets `NoNewPrivileges=true`, `ProtectSystem=strict`, `ProtectHome=yes`, `PrivateTmp=true`, `MemoryMax=`, `CPUQuota=`, `TasksMax=`) and adjust `MemoryMax` for 8 GB (`5G`) vs 16 GB (`11G`).
3. Lock down Hermes config via `terminal` (`hermes config set` / `security_policy.yaml`) per `references/agent-gateway-and-malware-defense.md`: explicit platform user allowlists, `approvals.mode: smart` (or `manual`), `approvals.unattended_mode: deny`, `approvals.deny` globs, `security.allow_private_urls: false`, `security.allow_lazy_installs: false`, and `filesystem_restrictions`.
4. Bind any internal sidecar services to `127.0.0.1`, never `0.0.0.0`. If exposing an Nginx edge on `80/443`, include a `default_server` reject block (`444` on 80, `ssl_reject_handshake on;` on 443).

### 4. Harden against cryptominers, malware, and lateral leaks

1. **Supply chain:** Freeze Python/Node dependencies during setup; keep `security.allow_lazy_installs: false` and never run `pip install` or `npm install` as `root` inside an agent runtime. Run `hermes doctor` after updates.
2. **Sibling secret isolation:** Set `0600` on unrelated `.env` files and `0750` on sibling non-web folders. Never `chmod 750` a shared parent while `svc-*` apps still live inside it.
3. **Audit periodically** through `terminal`:

```bash
sudo bash scripts/check-miner-malware.sh
```

## Pitfalls

- **`chmod 700 /root/.hermes` breaks non-root services:** resets the POSIX ACL `mask` to `---`, revoking effective `--x` traverse while the web frontend still returns 200. Host client agent homes under `/var/lib/hermes-agent`, or fix with `setfacl -m m::x` and test `sudo -u svc-<app> test -r`.
- **Never `chmod 750` a shared `/root/projects` parent** while `svc-*` apps live inside it; tighten sibling folders individually first or move apps to `/opt/<app>`.
- **`ProtectSystem=strict` only blocks writes, not reads:** inspect local writes first for `ReadWritePaths=`, and fix read isolation via `0600`/`0750` permissions.
- **Multi-worker `gunicorn` breaks `SocketIO` / ACP pools:** apps using `flask_socketio` (`async_mode="threading"`) or in-memory process dicts must run single-worker (`-w 1 --threads 8`), not `-w 2+`.
- **Check skill docs before disabling `terminal`:** companion local servers called over `127.0.0.1` via `curl` break if `terminal` is disabled without checking.
- **Staging `/etc/*` edits:** `write_file` and `patch` refuse `/etc/*` paths; stage files in scratch with `write_file` and install via `terminal` using `install -m 0644`.
- **Never run `reboot` from an interactive session on the target host**—verify all units are `enabled` and instruct the user to run `reboot`.

## Verification

Run the audit script through `terminal` on the hardened host and confirm zero `[FAIL]` items and all gateway/firewall checks pass:

```bash
sudo bash scripts/check-miner-malware.sh --verify
```
