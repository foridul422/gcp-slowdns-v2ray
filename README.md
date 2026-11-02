# ⚡ GCP SlowDNS + V2Ray One-Click Auto-Deploy ⚡

Automatic deployment of SlowDNS (DNSTT) and V2Ray (VMess) on Google Cloud Platform via Google Cloud Shell.

## 🚀 Quick Run (Google Cloud Shell)

Just open **Google Cloud Shell** and paste this one command:

```bash
curl -fsSL https://raw.githubusercontent.com/foridul422/gcp-slowdns-v2ray/main/deploy.sh | bash
```

### Or with your custom Cloudflare Token:
```bash
curl -fsSL https://raw.githubusercontent.com/foridul422/gcp-slowdns-v2ray/main/deploy.sh | bash -s -- YOUR_CLOUDFLARE_TOKEN
```

---

## 🛠️ What this script does automatically:

1. **Firewall Setup**: Opens UDP 53 (DNS), TCP 22 (SSH), TCP 80/443, and TCP 10086 (VMess).
2. **Zone Detection**: Automatically checks allowed zones under GCP Organization Policies and deploys in the lowest-latency zone available (Asia/US/EU).
3. **VM Instance**: Provisions an `e2-medium` Ubuntu 22.04 LTS VM.
4. **Optimized SlowDNS**: Installs high-performance `dnstt-server` with 64MB UDP buffer, BBR congestion control, and tuned kernel parameters.
5. **Xray (V2Ray)**: Configures VMess TCP inbound on port `10086`.
6. **Cloudflare DDNS**: Automatically updates `ns.foridul.pp.ua` to point to the newly created VM's public IP.
7. **SSH over SlowDNS**: Configures user `foridul` with password auth for direct SSH tunneling over DNS.

---

## 📱 Client Configuration (HTTP Custom / Netmod / NapsternetV / V2RayNG)

- **SlowDNS Nameserver (NS)**: `ns.foridul.pp.ua`
- **SlowDNS Domain**: `dns.foridul.pp.ua`
- **Public Key**: `58a0eeb51c71ad9fe39997ded7cf4e1f9700d497edd47af5c2c42a66611bc34c`

### VMess Inbound:
- **Address**: `127.0.0.1`
- **Port**: `10086`
- **UUID**: `60c44ed2-4dd4-43ab-9a66-a0b40623a1d4`
- **AlterID**: `0`
- **Network**: `tcp`

### SSH Login (Optional):
- **Host**: `127.0.0.1` / Port: `22`
- **User**: `foridul`
- **Password**: `foridul123`
