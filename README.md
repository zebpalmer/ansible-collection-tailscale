# zebpalmer.tailscale

Ansible collection for installing and configuring Tailscale on Ubuntu. Provides composable per-host/per-group feature flags so you never write raw CLI argument strings in inventory, and uses OAuth client authentication to eliminate 90-day auth key rotation.

**Ubuntu only** (Jammy 22.04, Noble 24.04). Requires ansible-core 2.18+.

---

## How it works

1. **install** — adds the official Tailscale apt repo + GPG key, installs the package
2. **configure** — enables IPv4/IPv6 forwarding, merges tags, constructs `tailscale_args` from composable vars
3. **up** — runs `tailscale up` only when config has changed or the node is disconnected (idempotency via SHA-256 state hash)
4. **post** — applies `tailscale set` settings (auto-update)

Run this role **last** in your playbook to avoid losing SSH connectivity to a host mid-play.

---

## Installation

### From Ansible Galaxy

```yaml
# requirements.yml
collections:
  - name: zebpalmer.tailscale
    version: "0.7.0"
```

### From GitHub (pin to a tag)

```yaml
# requirements.yml
collections:
  - name: zebpalmer.tailscale
    source: https://github.com/zebpalmer/ansible-collection-tailscale
    type: git
    version: "0.7.0"
```

---

## Authentication — OAuth clients, not auth keys

Use a **Tailscale OAuth client secret** (`tskey-client-...`) as `tailscale_authkey`. OAuth secrets never expire, eliminating the 90-day rotation problem that plagues auth key-based automation.

The role uses a two-step flow so the long-lived OAuth secret never appears in the process list:

1. `POST /api/v2/oauth/token` — exchanges `client_id` + `client_secret` for a short-lived access token (HTTPS only, no process exposure)
2. `POST /api/v2/tailnet/-/keys` — uses the access token to create a one-time auth key expiring in 5 minutes (HTTPS only, no process exposure)
3. `tailscale up --authkey` — the one-time key appears briefly in the process list but is worthless once used or expired

### 1. Ensure your tags exist in the ACL

All tags must be declared in your Tailscale ACL policy (**admin console → Access Controls**). `tag:ansible-managed` is the role's fixed managed tag and must always be present:

```json
"tagOwners": {
  "tag:ansible-managed": ["autogroup:admin"],
  "tag:servers":         ["autogroup:admin"],
  "tag:connector":       ["autogroup:admin"]
}
```

### 2. Create the OAuth client

1. **Tailscale admin console → Settings → Trust Credentials → Create OAuth client**
2. Scope: **Auth Keys → Write**
3. Tags: assign **`ansible-managed`** — this is the only tag you ever need on the OAuth client, because the role always stamps it onto every node
4. Copy the **Client ID** and **Client Secret** — the secret is shown **only once**

### 3. Store the credentials

The **Client ID** is not sensitive — store it in plain text:

```yaml
tailscale_oauth_client_id: "your-client-id-here"
```

The **Client Secret** must be vault-encrypted:

```bash
ansible-vault encrypt_string 'tskey-client-YOUR_SECRET_HERE' --name tailscale_authkey
```

Paste the output into your `group_vars/all.yml`:

```yaml
tailscale_oauth_client_id: "your-client-id-here"
tailscale_authkey: !vault |
  $ANSIBLE_VAULT;1.1;AES256
  ...
```

### 4. Install the collection

```bash
ansible-galaxy collection install -r requirements.yml
```

To upgrade to a newer version after updating `requirements.yml`:

```bash
ansible-galaxy collection install -r requirements.yml --force
```

### Prevent node key expiry

By default Tailscale node keys expire after 180 days, disconnecting the node until it re-authenticates. For long-lived servers, disable this in your ACL policy:

```json
"nodeAttrs": [
  {
    "target": ["tag:servers"],
    "attr": ["noExpiry"]
  }
]
```

This is a one-time ACL change per tailnet — it applies to all nodes carrying the matched tag, including existing ones. Nodes registered with `tailscale_oauth_ephemeral: false` (the default) will stay connected indefinitely without any re-auth runs.

---

## Variables

All variables have defaults in `roles/machine/defaults/main.yml`. Override at the group or host level.

### Authentication

| Variable | Default | Description |
|---|---|---|
| `tailscale_oauth_client_id` | `""` | OAuth client ID. Not sensitive — store in plain text |
| `tailscale_authkey` | `""` | OAuth client secret (`tskey-client-...`). Vault-encrypt this value |
| `tailscale_oauth_ephemeral` | `false` | `true` = node removed from tailnet when offline (containers/CI). `false` = persistent server. **Keep `false` for servers** — ephemeral nodes lose credentials on removal and cannot reconnect after reboot without a fresh ansible run |
| `tailscale_oauth_preauthorized` | `true` | Skip manual device approval in the admin console. Keep `true` for automation |
| `tailscale_up_timeout` | `"120"` | Seconds to wait for `tailscale up` |
| `tailscale_insecurely_log_authkey` | `false` | Log the auth key in plain text. Keep `false` in production |

### Package

| Variable | Default | Description |
|---|---|---|
| `tailscale_package_state` | `present` | `present` — install once, never upgrade on routine runs. `latest` — always upgrade. `absent` — remove |

### Tags

| Variable | Default | Description |
|---|---|---|
| `tailscale_oauth_tag` | `"ansible-managed"` | Always applied to every node. This is the only tag the OAuth client needs assigned to it in Trust Credentials. Must exist in ACL `tagOwners` |
| `tailscale_tags` | `["servers"]` | Additional tags for role/environment grouping. `"tag:"` prefix added automatically. Must exist in ACL `tagOwners`. Defaults to `["servers"]` if empty |

### Feature flags

| Variable | Default | Description |
|---|---|---|
| `tailscale_ssh` | `false` | Enable Tailscale SSH |
| `tailscale_accept_dns` | `true` | Accept DNS config pushed from the tailnet |
| `tailscale_advertise_exit_node` | `false` | Advertise this host as an exit node |
| `tailscale_accept_routes` | `false` | Accept subnet routes advertised by other nodes |
| `tailscale_snat_subnet_routes` | `true` | Source-NAT traffic on subnet routes |
| `tailscale_stateful_filtering` | `false` | Enable stateful packet filtering |
| `tailscale_advertise_routes` | `false` | Comma-separated CIDRs to advertise as subnet routes, e.g. `"10.0.1.0/24,10.0.2.0/24"`. Omits the flag entirely when `false` or empty |
| `tailscale_connector` | `false` | Advertise as an [app connector](https://tailscale.com/kb/1281/app-connectors). Appends `tailscale_connector_tag` to tags automatically |
| `tailscale_connector_tag` | `"connector"` | Tag appended when `tailscale_connector: true` |
| `tailscale_auto_update` | `false` | Tailscale daemon auto-update. Disabled by default — a restart in prod causes brief connectivity loss. Use a dedicated update playbook instead |

---

## Usage

### Playbook

```yaml
- name: Tailscale
  hosts: your_servers
  become: true
  gather_facts: true
  roles:
    - role: zebpalmer.tailscale.machine
  tags:
    - tailscale
```

Run only the tailscale role:

```bash
ansible-playbook site.yml --tags tailscale
ansible-playbook site.yml --tags tailscale --limit myserver.example.com
```

---

## Examples

### Standard server

No host vars needed — `group_vars` defaults apply. The node registers with `tag:servers`, no routes advertised, Tailscale DNS accepted.

---

### Exit node

```yaml
# host_vars/gateway.example.com.yml
tailscale_advertise_exit_node: true
tailscale_accept_routes: true
tailscale_tags:
  - "servers"
  - "prod"
```

> Approve the exit node in the admin console after first run (Machines → Edit → Use as exit node), or pre-approve via ACL policy.

---

### Subnet router

Advertises on-premises CIDRs into the tailnet so devices can reach them without a Tailscale client install.

```yaml
# host_vars/onprem-gateway.example.com.yml
tailscale_advertise_routes: "10.10.0.0/24,10.20.0.0/24"
tailscale_tags:
  - "servers"
  - "onprem"
```

Approve the routes in the admin console after first run (Machines → Edit route settings), or pre-approve via ACL.

---

### App connector

An [app connector](https://tailscale.com/kb/1281/app-connectors) proxies access to specific domains/services for tailnet members without exposing a full subnet. Automatically appends `tag:connector` to the node's tags.

```yaml
# host_vars/connector.example.com.yml
tailscale_connector: true
tailscale_tags:
  - "servers"
  - "prod"
```

---

### Subnet router + app connector

A single host acting as both — common for an on-premises gateway.

```yaml
# host_vars/onprem-gateway.example.com.yml
tailscale_advertise_exit_node: true
tailscale_advertise_routes: "10.10.3.0/24,10.50.50.0/24"
tailscale_connector: true
tailscale_tags:
  - "servers"
  - "onprem"
```

---

### K8s / cluster nodes — disable route acceptance

Accepting routes on a cluster node can conflict with pod-network CIDRs (e.g. MetalLB). Disable at the group level.

```yaml
# group_vars/kubernetes.yml
tailscale_accept_routes: false
tailscale_accept_dns: false  # avoid split-DNS conflicts with CoreDNS
```

---

### Group-level tagging

Apply consistent tags to all nodes in a logical group without touching individual host files.

```yaml
# group_vars/production.yml
tailscale_tags:
  - "servers"
  - "prod"
```

```yaml
# group_vars/staging.yml
tailscale_tags:
  - "servers"
  - "staging"
```

---

## Idempotency

The role stores a SHA-256 hash of `tailscale_args` + effective tags in `/var/lib/tailscale-ansible.state`. `tailscale up` is skipped if the hash matches the stored value **and** the node is already connected. The auth key is excluded from the hash intentionally — rotating the OAuth secret does not trigger a re-up.

---

## Debugging

Inspect the constructed args on any managed host:

```bash
cat /opt/ansible_tailscale_args.txt   # root-readable only (0600)
tailscale status
tailscale ip
```

---

## License

MIT — see [LICENSE](LICENSE).

Portions derived from [ansible-collection-tailscale](https://github.com/artis3n/ansible-collection-tailscale), Copyright (c) Ari Kalfus, MIT licensed.
