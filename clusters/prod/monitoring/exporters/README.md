# Exporters for the Synology NAS and Proxmox VE

| Exporter | Talks to | Auth | Scrape |
|---|---|---|---|
| `snmp-exporter` | `synology.shakir.cloud` (10.10.50.38) udp/161 | SNMPv3 authPriv (SHA/AES) | health every 3m, system every 60s |
| `pve-exporter` | `10.10.50.20:8006` (PVE API, direct, not via the NAS proxy) | API token `monitoring@pve!prometheus`, role PVEAuditor | every 60s |

Nothing is installed on the NAS or the PVE host. Credentials live in Bitwarden
Secrets Manager and reach the pods through BitwardenSecrets in
`bootstrap/bw-secrets/monitoring.yaml` (`snmp-synology`, `pve-exporter`).

Alerts: `rules-nas-pve.yaml`. Dashboards: Grafana > Homelab > *Synology / NAS* and *Proxmox VE*.

## One-time manual setup

Do steps 1–3 **before merging** a change that adds or renames these BitwardenSecrets.
A BitwardenSecret that never syncs fails the `bw-secrets` health check, and every
Kustomization that depends on `bw-secrets` (apps, monitoring, csi-driver-proxmox)
stops reconciling until it does.

### 1. Synology: SNMPv3

DSM > **Control Panel > Terminal & SNMP > SNMP**:

1. Tick **Enable SNMP service**.
2. Leave **SNMPv1, SNMPv2c** unticked (community strings are plaintext).
3. Tick **SNMPv3 service**:
   - Username: `monitoring`
   - Protocol: **SHA**, Password: a random string, at least 8 characters
   - Tick **Enable SNMP privacy**: Protocol **AES**, Password: a *different* random string, at least 8 characters
4. **Apply**.
5. If the DSM firewall is on (Control Panel > Security > Firewall), allow
   **UDP 161** from the K3s nodes `10.10.50.40-10.10.50.44`. Pod traffic to the LAN
   leaves through the node IPs.

Optional, same NAS: **Log Center > Log Sending**: server `logs.shakir.cloud`, port
`1514`, protocol **TCP**, format **IETF (RFC 5424)**.

### 2. Proxmox VE: dedicated read-only user and token

No root token. `monitoring@pve` has no password, so it cannot log in to the UI.
It is only usable through the API token below, which only has read (audit) rights.

**Shell** (on the PVE host, as root, once):

```bash
# user in the PVE realm, no password = no interactive login
pveum user add monitoring@pve --comment "Prometheus pve-exporter (read-only, token only)"

# read-only on everything: nodes, guests, storage (Sys/VM/Datastore.Audit)
pveum acl modify / --users monitoring@pve --roles PVEAuditor

# token with privilege separation: it gets only what is granted to the token itself
pveum user token add monitoring@pve prometheus --privsep 1 \
  --comment "pve-exporter in K3s (flux: clusters/prod/monitoring/exporters)"
pveum acl modify / --tokens 'monitoring@pve!prometheus' --roles PVEAuditor
```

`token add` prints the **value** (a UUID) once. Copy it for step 3.

**UI equivalent** (Datacenter > Permissions):

1. **Users > Add**: User name `monitoring`, Realm *Proxmox VE authentication server*, no password.
2. **Permissions > Add > User Permission**: Path `/`, User `monitoring@pve`, Role `PVEAuditor`.
3. **API Tokens > Add**: User `monitoring@pve`, Token ID `prometheus`, **Privilege Separation ticked**, no expiry. Copy the secret.
4. **Permissions > Add > API Token Permission**: Path `/`, Token `monitoring@pve!prometheus`, Role `PVEAuditor`.

**Check it** (from a machine on the LAN):

```bash
curl -sk -H 'Authorization: PVEAPIToken=monitoring@pve!prometheus=<token value>' \
  https://10.10.50.20:8006/api2/json/cluster/resources | head -c 300
```

You should see JSON with your nodes, VMs and storages. A `401` means the token or
ACL is wrong. An empty `data: []` means the token's ACL (step 4) is missing.

The user and token name are not secret and live in `release-pve.yaml`
(`PVE_USER`, `PVE_TOKEN_NAME`). If you choose other names, change them there.

### 3. Bitwarden Secrets Manager

Create these four secrets in a project that the **monitoring** machine account can
read (the account whose token is `monitoring/bw-auth-token`):

| Bitwarden secret (suggested name) | Value | Kubernetes Secret / key |
|---|---|---|
| `synology-snmp-username` | `monitoring` | `snmp-synology` / `SNMP_USERNAME` |
| `synology-snmp-auth-password` | SNMPv3 auth password (step 1) | `snmp-synology` / `SNMP_AUTH_PASSWORD` |
| `synology-snmp-priv-password` | SNMPv3 privacy password (step 1) | `snmp-synology` / `SNMP_PRIV_PASSWORD` |
| `pve-exporter-token-value` | token UUID (step 2) | `pve-exporter` / `PVE_TOKEN_VALUE` |

Then copy each secret's **ID** (Secrets Manager > secret > ID) into
`bootstrap/bw-secrets/monitoring.yaml`, replacing the four `REPLACE-ME-*` values.

### 4. Merge and verify

```bash
flux get kustomizations bw-secrets monitoring-exporters
kubectl -n monitoring get secret snmp-synology pve-exporter
kubectl -n monitoring get pods -l 'app.kubernetes.io/instance in (snmp-exporter,pve-exporter)'
```

In Prometheus, `up{job=~"synology-health|synology-system|pve"}` should be `1` for
all three. Then open Grafana > Homelab.

## HDD hibernation

If the NAS HDDs are set to hibernate, keep an eye on whether they still do once SNMP
polling starts (DSM > Hardware & Power > HDD Hibernation, and Log Center). The
health scrape is already 3 minutes and skips the SMART attribute table. If the disks
stop sleeping, raise `interval` on `synology-health` in `release-snmp.yaml`. Above
~4m, series go stale between scrapes (Prometheus' 5m lookback), so the rules would
need `max_over_time(...[10m])` wrappers.

## Rotating credentials

- **SNMP:** change the passwords in DSM and in Bitwarden. sm-operator updates the
  Secret within an hour, but env vars are only read at start, so restart the pod:
  `kubectl -n monitoring rollout restart deploy/snmp-exporter-prometheus-snmp-exporter`.
- **PVE:** `pveum user token add monitoring@pve prometheus2 --privsep 1`, grant the ACL,
  update Bitwarden and `PVE_TOKEN_NAME`, merge, then `pveum user token remove monitoring@pve prometheus`.
