# Client VPS Architecture (Contabo 8-16 GB, No Client Tailscale)

Reference for provisioning isolated Contabo client VMs (8 to 16 GB RAM) without forcing non-technical clients onto Tailscale.

## Core Principles

1. **One client = one VPS.** Never co-tenant two clients—especially AI-agent workloads—on one VPS (shared kernel, cross-tenant file-read risk, noisy-neighbor abuse risk, account-wide Contabo suspension risk).
2. **Separate the admin plane from the user plane.** Choose the access model based on who actually logs into the OS:
   - **Operator-managed (client only uses Telegram/Slack/Discord or a web app):** Keep WireGuard or Tailscale strictly on your own admin plane—the client never installs or sees a VPN. Block public port 22 completely. If the gateway uses outbound polling/WebSocket (Telegram, Slack Socket Mode, Discord), open **zero** public inbound ports. Open `80/443` via Nginx only if serving a web UI or webhook.
   - **Client self-managed:** Do not expose browser root/sudo shells (`ttyd`) behind email OTP (one phished inbox = root), and do not expect non-technical clients to install `cloudflared` and edit `~/.ssh/config` for `cloudflared access ssh`. Give them an authenticated web UI for routine tasks and restrict SSH via Contabo's Cloud Firewall IP allowlist (or disable SSH and use Contabo's Customer Panel VNC console for break-glass).
   - **Cloudflare Tunnel + Access:** Use only when internal/admin web dashboards must stay unreachable on public ports and the client already uses Cloudflare DNS. Always run `cloudflared` as a dedicated `svc-cloudflared` user (`ProtectSystem=strict`, `ProtectHome=yes`), never `root`.

## 8-16 GB Contabo Sizing & Stability

- **8 GB VPS (e.g. Cloud VPS 10 / 20 tier):**
  - Add a **2-4 GB swapfile** (`/swapfile`, `chmod 600`, `vm.swappiness=10`) so Playwright/Chromium, package builds, or concurrent gateway turns do not trigger OOM kills.
  - Cap the agent gateway unit at `MemoryMax=5G` (hard) / `MemoryHigh=4G` and `CPUQuota=300%` (leaves headroom for OS, SSH, `fail2ban`, and DB).
- **16 GB VPS:**
  - Add a **4 GB swapfile**.
  - Cap the agent gateway unit at `MemoryMax=11G` / `MemoryHigh=9G` (or reserve memory cleanly if running Docker sandboxes alongside the gateway).
- **Why resource caps matter for security:** A compromised dependency or cryptominer trying to saturate all vCPUs or RAM gets throttled by cgroups before it can lock out SSH or crash monitoring.

## Contabo-Specific Baseline

- **Cloud Firewall:** Contabo includes a network-level Cloud Firewall free on VPS/VDS instances (API specs may still carry legacy "paid add-on" text). Assign an inbound policy in front of `ufw` to drop port 22 at the network edge. Remember Contabo's Cloud Firewall filters **inbound only**—OS-level `ufw` / `nftables` rules remain mandatory for outbound abuse defense.
- **First-boot provisioning (`cloud-init` vs UI order):**
  - **API order (`POST /v1/compute/instances`):** Pass `sshKeys` (Secrets API `secretId`s) and `userData` (`templates/cloud-init-contabo.yaml`) so SSH keys, `PasswordAuthentication no`, `ufw`, and swap apply from second one.
  - **Affiliate-link / UI self-order:** Contabo emails a plaintext root password by default. Immediately run `scripts/harden-contabo-agent.sh` on first login to create the non-root admin user, install SSH keys, set `PasswordAuthentication no` and `PermitRootLogin no`, lock/scramble the root password (`passwd -l root`), and verify a clean reboot.
- **Tooling weight:** Prefer `templates/cloud-init-contabo.yaml` + `scripts/harden-contabo-agent.sh` (or a small Ansible playbook) over Terraform for small fleets or multi-account affiliate setups where clients own separate Contabo accounts.
- **Egress filtering:** Do not maintain IP-based `nftables` egress allowlists for general AI agents—CDN IPs for OpenRouter, Anthropic, Telegram, Cloudflare, and `apt` mirrors rotate and break updates. Instead:
  - Block outbound SMTP (`25`, `465`, `587`) so a compromised app cannot send spam and trigger an account-wide Contabo abuse suspension.
  - Block common Stratum mining ports (`3333`, `4444`, `5555`, `7777`, `8888`, `9999`, `14433`, `14444`, `45700`) outbound.
  - Add an outbound HTTP forward proxy (Squid/Tinyproxy) only when a client explicitly requires strict domain-level egress allowlisting.
- **Patching and backups:**
  - Enable `unattended-upgrades` (security origins only). Prefer a `/var/run/reboot-required` healthcheck alert over blind `04:00` `Automatic-Reboot` if agents run scheduled cron jobs or hold in-memory state.
  - Snapshots are not backups: schedule nightly encrypted `restic` backups (database `pg_dump` + `/var/lib/hermes-agent` state) to Contabo Object Storage and test restores quarterly.
