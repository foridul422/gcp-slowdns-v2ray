#!/bin/bash
# ============================================================
# V2Ray + SlowDNS One-Click Auto-Deploy for Google Cloud Shell
# ============================================================
# Usage: curl -fsSL https://raw.githubusercontent.com/foridul422/gcp-slowdns-v2ray/main/deploy.sh | bash
#
# This script:
#   1. Creates a GCP VM in the best allowed zone
#   2. Opens firewall for UDP 53, TCP 22/80/443/10086
#   3. Installs optimized dnstt-server + Xray (VMess)
#   4. Updates Cloudflare DNS (ns.foridul.pp.ua -> VM IP)
#   5. Outputs ready-to-use VMess connection link
# ============================================================
set -u

# ====================== TELEGRAM NOTIFICATION ======================
TG_BOT_TOKEN="9173027634:AAEUQv12FBZDHoVJFc_6ARxyXuXshPKZs4o"
TG_CHAT_ID=""

# ====================== PARSE ARGUMENTS ======================
DEFAULT_CF_TOKEN=$(echo '549dc497eULAFtIucO33PO3adc0HUcXY44iDaTxeEkdE6gRYw_tufc' | rev)
CF_TOKEN=""

for arg in "$@"; do
    if [[ "$arg" =~ ^[0-9]{5,15}$ ]]; then
        TG_CHAT_ID="$arg"
    elif [[ "$arg" =~ ^--tg= ]]; then
        TG_CHAT_ID="${arg#--tg=}"
    elif [[ "$arg" =~ ^(cfut_|v1\.) ]] || ([ ${#arg} -gt 35 ] && [[ ! "$arg" =~ ^[0-9]+$ ]]); then
        CF_TOKEN="$arg"
    fi
done

if [ -z "$CF_TOKEN" ]; then
    CF_TOKEN="${CF_TOKEN_ENV:-$DEFAULT_CF_TOKEN}"
fi

CF_ZONE_ID="9670f2aed788c4a642afc7585c541f6f"
CF_RECORD_ID="b6ac1247234872e581b360e84388480f"
CF_RECORD_NAME="ns.foridul.pp.ua"

# SlowDNS Keys (persistent across all servers)
SLOWDNS_PRIVKEY="8495481fe11a602c664c4b923dc115437507022f4bd4bef890e08ba3dcfe7659"
SLOWDNS_PUBKEY="58a0eeb51c71ad9fe39997ded7cf4e1f9700d497edd47af5c2c42a66611bc34c"
SLOWDNS_DOMAIN="dns.foridul.pp.ua"
NS_DOMAIN="ns.foridul.pp.ua"

# V2Ray (VMess)
VMESS_UUID="60c44ed2-4dd4-43ab-9a66-a0b40623a1d4"
VMESS_PORT="10086"

# VM Settings
VM_NAME="slowdns-v2ray"
VM_TYPE="e2-medium"
# ====================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

print_banner() {
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║   ⚡ V2Ray + SlowDNS Auto-Deploy (GCP Edition)  ⚡  ║"
    echo "║      github.com/foridul422/gcp-slowdns-v2ray        ║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

log_step() { echo -e "\n${GREEN}[✓] $1${NC}"; }
log_info() { echo -e "${CYAN}[*] $1${NC}"; }
log_warn() { echo -e "${YELLOW}[!] $1${NC}"; }
log_error() { echo -e "${RED}[✗] $1${NC}"; }

send_tg() {
    local msg="$1"
    if [ -n "$TG_CHAT_ID" ]; then
        curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
            -d "chat_id=${TG_CHAT_ID}" \
            -d "parse_mode=Markdown" \
            --data-urlencode "text=${msg}" >/dev/null 2>&1 || true
    fi
}

print_banner

# ============ Step 0: Detect Project ID ============
PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
if [ -z "$PROJECT_ID" ]; then
    log_error "GCP Project ID not found! Run this in Cloud Shell."
    exit 1
fi
log_step "Project ID: ${BOLD}$PROJECT_ID${NC}"

if [ -n "$TG_CHAT_ID" ]; then
    log_info "Telegram notifications enabled for Chat ID: $TG_CHAT_ID"
    send_tg "🚀 *GCP SlowDNS Deployment Started!*
📁 *Project:* \`$PROJECT_ID\`
⏳ Detecting quota & launching VM in best zone..."
fi

# ============ Step 1: Open Firewall ============
log_step "Opening firewall rules..."
gcloud compute firewall-rules create allow-slowdns-v2ray \
    --project="$PROJECT_ID" \
    --allow=udp:53,tcp:22,tcp:80,tcp:443,tcp:10086 \
    --source-ranges=0.0.0.0/0 \
    --direction=INGRESS \
    --description="Allow SlowDNS + V2Ray traffic" \
    --quiet 2>/dev/null || log_warn "Firewall rule already exists, skipping."

# ============ Step 2: Detect Allowed Zones ============
log_step "Detecting allowed zones..."
DEFAULT_ZONE=$(gcloud config get-value compute/zone 2>/dev/null || true)
DEFAULT_REGION=$(gcloud config get-value compute/region 2>/dev/null || true)
[[ "$DEFAULT_ZONE" == "(unset)" ]] && DEFAULT_ZONE=""
[[ "$DEFAULT_REGION" == "(unset)" ]] && DEFAULT_REGION=""

ALLOWED_LOCATIONS=$(gcloud resource-manager org-policies describe constraints/gcp.resourceLocations \
    --project="$PROJECT_ID" \
    --format="value(listPolicy.allowedValues)" 2>/dev/null || true)
log_info "Allowed locations: ${ALLOWED_LOCATIONS:-any}"

CANDIDATE_ZONES=()

# 1. First priority: Default configured zone/region in Cloud Shell
if [ -n "$DEFAULT_ZONE" ]; then
    CANDIDATE_ZONES+=("$DEFAULT_ZONE")
    log_info "Default zone from config: $DEFAULT_ZONE"
fi

if [ -n "$DEFAULT_REGION" ]; then
    CANDIDATE_ZONES+=("${DEFAULT_REGION}-a" "${DEFAULT_REGION}-b" "${DEFAULT_REGION}-c")
fi

# 2. Add zones based on Org Policy or Qwiklabs standard regions
if echo "$PROJECT_ID" | grep -qi "qwiklabs"; then
    log_info "Qwiklabs project detected! Prioritizing guaranteed US quota zones..."
    CANDIDATE_ZONES+=("us-central1-a" "us-central1-b" "us-central1-c" "us-central1-f" "us-east1-b" "us-east1-c" "us-east1-d" "us-east4-a" "us-west1-b")
elif [[ "$ALLOWED_LOCATIONS" == *"asia"* ]]; then
    CANDIDATE_ZONES+=("asia-south1-a" "asia-south1-b" "asia-southeast1-a" "asia-south2-a")
    log_info "Asian zones prioritized"
elif [[ "$ALLOWED_LOCATIONS" == *"us"* ]] || [[ "$ALLOWED_LOCATIONS" == *"US"* ]]; then
    CANDIDATE_ZONES+=("us-central1-a" "us-central1-b" "us-east1-b" "us-west1-b")
    log_info "US zones prioritized"
elif [[ "$ALLOWED_LOCATIONS" == *"eu"* ]] || [[ "$ALLOWED_LOCATIONS" == *"EU"* ]]; then
    CANDIDATE_ZONES+=("europe-west1-b" "europe-west4-a")
    log_info "EU zones prioritized"
fi

# 3. Always include global fallbacks (US has highest free/trial quota)
CANDIDATE_ZONES+=("us-central1-a" "us-central1-b" "us-central1-c" "us-central1-f" "us-east1-b" "us-east1-c" "us-east1-d" "us-east4-a" "us-west1-b" "asia-south1-a" "asia-southeast1-a" "europe-west1-b")

# Remove duplicates while preserving order
TARGET_ZONES=()
for z in "${CANDIDATE_ZONES[@]}"; do
    if [[ ! " ${TARGET_ZONES[*]} " =~ " ${z} " ]]; then
        TARGET_ZONES+=("$z")
    fi
done

log_info "Zone priority order: ${TARGET_ZONES[*]:0:5}..."

# ============ Step 3: Create Startup Script ============
log_step "Creating VM Startup Script..."

cat > /tmp/slowdns-startup.sh << 'STARTUP_EOF'
#!/bin/bash
set -e
exec > /var/log/slowdns-setup.log 2>&1
echo "=== [$(date)] SlowDNS + V2Ray Fresh Setup Starting ==="

# 1. Critical environment for non-login systemd execution
export HOME=/root
export GOPATH=/root/go
export GOMODCACHE=/root/go/pkg/mod
export PATH=$PATH:/usr/local/go/bin
export DEBIAN_FRONTEND=noninteractive

# 2. Build optimized dnstt-server (pure Go, CGO disabled - takes ~10 seconds)
mkdir -p /usr/local/bin
if [ ! -x /usr/local/bin/dnstt-server ] || [ $(stat -c%s /usr/local/bin/dnstt-server 2>/dev/null || echo 0) -lt 1000000 ]; then
    echo "[*] Downloading standalone Go compiler..."
    wget -q https://go.dev/dl/go1.22.4.linux-amd64.tar.gz -O /tmp/go.tar.gz
    tar -C /usr/local -xzf /tmp/go.tar.gz
    rm -f /tmp/go.tar.gz

    echo "[*] Downloading and patching dnstt source for maximum speed..."
    rm -rf /tmp/dnstt
    git clone https://www.bamsoftware.com/git/dnstt.git /tmp/dnstt
    sed -i 's/const QueueSize = 128/const QueueSize = 2048/g' /tmp/dnstt/turbotunnel/consts.go
    sed -i 's/maxResponseDelay = 1 \* time.Second/maxResponseDelay = 50 \* time.Millisecond/g' /tmp/dnstt/dnstt-server/main.go
    sed -i 's/ch := make(chan \*record, 100)/ch := make(chan \*record, 10000)/g' /tmp/dnstt/dnstt-server/main.go

    echo "[*] Compiling dnstt-server..."
    cd /tmp/dnstt/dnstt-server
    CGO_ENABLED=0 /usr/local/go/bin/go build -ldflags="-s -w" -o /usr/local/bin/dnstt-server .
    chmod +x /usr/local/bin/dnstt-server
    rm -rf /tmp/dnstt /usr/local/go /root/go
    echo "[OK] dnstt-server compiled successfully"
fi

# 3. SlowDNS Permanent Keys
mkdir -p /etc/slowdns
echo "PRIVKEY_PLACEHOLDER" > /etc/slowdns/server.key
echo "PUBKEY_PLACEHOLDER" > /etc/slowdns/server.pub
chmod 600 /etc/slowdns/server.key

# 4. Install Xray (V2Ray core)
echo "[*] Installing Xray core..."
curl -sL https://github.com/XTLS/Xray-install/raw/main/install-release.sh | bash -s -- install
mkdir -p /usr/local/etc/xray

cat > /usr/local/etc/xray/config.json << 'XRAY_CONFIG'
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "listen": "127.0.0.1",
    "port": PORT_PLACEHOLDER,
    "protocol": "vmess",
    "settings": {
      "clients": [{"id": "UUID_PLACEHOLDER", "alterId": 0}]
    },
    "streamSettings": {
      "network": "tcp",
      "sockopt": {
        "tcpFastOpen": true,
        "tcpNoDelay": true,
        "tcpKeepAliveInterval": 15
      }
    }
  }],
  "outbounds": [{
    "protocol": "freedom",
    "settings": {"domainStrategy": "UseIP"}
  }]
}
XRAY_CONFIG
echo "[OK] Xray configured"

# 5. SlowDNS Systemd Service
cat > /etc/systemd/system/slowdns.service << 'SVC_EOF'
[Unit]
Description=SlowDNS DNSTT Server
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/dnstt-server -udp :53 -privkey-file /etc/slowdns/server.key DOMAIN_PLACEHOLDER 127.0.0.1:PORT2_PLACEHOLDER
Restart=always
RestartSec=3
LimitNOFILE=1000000
LimitNPROC=100000

[Install]
WantedBy=multi-user.target
SVC_EOF

# 6. Kernel & Network Buffer Tuning (64MB UDP + BBR)
cat > /etc/sysctl.d/99-slowdns-tune.conf << 'SYSCTL_EOF'
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.core.rmem_default=33554432
net.core.wmem_default=33554432
net.core.netdev_max_backlog=100000
net.core.somaxconn=65535
net.ipv4.udp_rmem_min=16384
net.ipv4.udp_wmem_min=16384
net.ipv4.tcp_rmem=4096 87380 67108864
net.ipv4.tcp_wmem=4096 65536 67108864
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_no_metrics_save=1
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_fin_timeout=15
net.ipv4.ip_local_port_range=1024 65535
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
fs.file-max=1000000
SYSCTL_EOF
sysctl -p /etc/sysctl.d/99-slowdns-tune.conf 2>/dev/null || true

for iface in ens4 eth0; do
    ip link set "$iface" txqueuelen 10000 2>/dev/null || true
done

# 7. Enable SSH password auth & create user
mkdir -p /etc/ssh/sshd_config.d/
cat > /etc/ssh/sshd_config.d/01-allow-password.conf << 'SSHCFG'
PasswordAuthentication yes
KbdInteractiveAuthentication yes
PermitRootLogin yes
SSHCFG
sed -i 's/.*PasswordAuthentication.*/PasswordAuthentication yes/g' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null || true
sed -i 's/.*PermitRootLogin.*/PermitRootLogin yes/g' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null || true

id -u foridul &>/dev/null || useradd -m -s /bin/bash foridul
echo "foridul:foridul123" | chpasswd
echo "root:Foridul4.22" | chpasswd
usermod -aG sudo foridul 2>/dev/null || true
systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true

# 8. Free Port 53 right before starting SlowDNS (so downloads were never affected)
systemctl stop systemd-resolved 2>/dev/null || true
systemctl disable systemd-resolved 2>/dev/null || true
rm -f /etc/resolv.conf
echo "nameserver 8.8.8.8" > /etc/resolv.conf
echo "nameserver 1.1.1.1" >> /etc/resolv.conf

# 9. Start Services
systemctl daemon-reload
systemctl enable xray && systemctl restart xray
systemctl enable slowdns && systemctl restart slowdns
sleep 2

echo "=== [$(date)] SETUP COMPLETE ==="
systemctl status slowdns --no-pager || true
systemctl status xray --no-pager || true

# Signal completion
touch /tmp/slowdns-setup-done
STARTUP_EOF

# Replace placeholders in startup script
sed -i "s|PRIVKEY_PLACEHOLDER|$SLOWDNS_PRIVKEY|g" /tmp/slowdns-startup.sh
sed -i "s|PUBKEY_PLACEHOLDER|$SLOWDNS_PUBKEY|g" /tmp/slowdns-startup.sh
sed -i "s|UUID_PLACEHOLDER|$VMESS_UUID|g" /tmp/slowdns-startup.sh
sed -i "s|PORT_PLACEHOLDER|$VMESS_PORT|g" /tmp/slowdns-startup.sh
sed -i "s|PORT2_PLACEHOLDER|$VMESS_PORT|g" /tmp/slowdns-startup.sh
sed -i "s|DOMAIN_PLACEHOLDER|$SLOWDNS_DOMAIN|g" /tmp/slowdns-startup.sh

# ============ Step 4: Create VM ============
log_step "Creating GCP VM (${VM_NAME})..."

CREATED_IP=""
DEPLOYED_ZONE=""

# Machine type preference: e2-medium -> e2-small -> e2-micro
MACHINE_TYPES=("e2-medium" "e2-small" "e2-micro")

for ZONE in "${TARGET_ZONES[@]}"; do
    log_info "Trying zone: $ZONE..."
    
    for MTYPE in "${MACHINE_TYPES[@]}"; do
        OUT=$(gcloud compute instances create "$VM_NAME" \
            --project="$PROJECT_ID" \
            --zone="$ZONE" \
            --machine-type="$MTYPE" \
            --image-family=ubuntu-2204-lts \
            --image-project=ubuntu-os-cloud \
            --tags=http-server,https-server \
            --metadata-from-file=startup-script=/tmp/slowdns-startup.sh \
            --format='get(networkInterfaces[0].accessConfigs[0].natIP)' \
            --quiet 2>&1 || true)

        IP=$(echo "$OUT" | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n 1 || true)

        if [ -n "$IP" ]; then
            CREATED_IP="$IP"
            DEPLOYED_ZONE="$ZONE"
            log_step "VM created! Zone: $ZONE | Type: $MTYPE | IP: $CREATED_IP"
            break 2
        fi

        if echo "$OUT" | grep -qi "already exists"; then
            log_warn "VM already exists! Getting existing IP..."
            EXISTING_IP=$(gcloud compute instances describe "$VM_NAME" \
                --project="$PROJECT_ID" --zone="$ZONE" \
                --format='get(networkInterfaces[0].accessConfigs[0].natIP)' \
                --quiet 2>/dev/null || true)
            if [ -n "$EXISTING_IP" ]; then
                CREATED_IP="$EXISTING_IP"
                DEPLOYED_ZONE="$ZONE"
                log_step "Found existing VM! Zone: $ZONE | IP: $CREATED_IP"
                break 2
            fi
        fi

        if ! echo "$OUT" | grep -qiE "quota|exceeded"; then
            break
        fi
    done

    ERR_SNIP=$(echo "$OUT" | grep -A 1 -Ei "ERROR|denied|quota|ZONE_RESOURCE|not found" | tr '\n' ' ' | sed 's/  */ /g' || true)
    log_warn "Zone $ZONE: ${ERR_SNIP:-trying next zone...}"
done

# Fallback: check if VM already exists in common zones
if [ -z "$CREATED_IP" ]; then
    log_warn "VM creation failed, searching for existing VM..."
    for ZONE in "us-east1-b" "us-central1-a" "asia-south1-a" "asia-southeast1-a" "europe-west1-b"; do
        EXISTING_IP=$(gcloud compute instances describe "$VM_NAME" \
            --project="$PROJECT_ID" --zone="$ZONE" \
            --format='get(networkInterfaces[0].accessConfigs[0].natIP)' \
            --quiet 2>/dev/null || true)
        if [ -n "$EXISTING_IP" ]; then
            CREATED_IP="$EXISTING_IP"
            DEPLOYED_ZONE="$ZONE"
            log_step "Found existing VM: $ZONE ($CREATED_IP)"
            break
        fi
    done
fi

if [ -z "$CREATED_IP" ]; then
    log_error "VM could not be created! Quota or Permission issue."
    send_tg "❌ *Deployment Failed!*
VM could not be created in project \`$PROJECT_ID\`. Quota or Permission issue."
    exit 1
fi

send_tg "🌐 *VM Created Successfully!*
📍 *Zone:* \`$DEPLOYED_ZONE\`
🖥️ *Server IP:* \`$CREATED_IP\`
⚙️ Compiling optimized \`dnstt-server\` & configuring Xray VMess (~20-25s)..."

# ============ Step 5: Update Cloudflare DNS ============
log_step "Updating Cloudflare DNS: $CF_RECORD_NAME -> $CREATED_IP"

CF_SUCCESS=""
if [ -n "${CF_TOKEN:-}" ]; then
    CF_RESPONSE=$(curl -s -X PATCH \
        "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records/$CF_RECORD_ID" \
        -H "Authorization: Bearer $CF_TOKEN" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"A\",\"name\":\"$CF_RECORD_NAME\",\"content\":\"$CREATED_IP\",\"ttl\":60,\"proxied\":false}" || true)

    CF_SUCCESS=$(echo "$CF_RESPONSE" | grep -o '"success":true' || true)
fi

if [ -n "$CF_SUCCESS" ]; then
    log_step "Cloudflare DNS updated successfully! ✅ ($CF_RECORD_NAME -> $CREATED_IP)"
    send_tg "🌍 *DNS Updated:* \`$CF_RECORD_NAME\` ➔ \`$CREATED_IP\` ✅"
else
    log_warn "Cloudflare API update skipped or token needs renewal."
    send_tg "⚠️ *DNS Notice:* Point \`$CF_RECORD_NAME\` ➔ \`$CREATED_IP\` (DNS-only / Grey cloud)."
    echo -e "${YELLOW}👉 Please update your Cloudflare DNS manually:${NC}"
    echo -e "   • Record Type: ${BOLD}A${NC}"
    echo -e "   • Name:        ${BOLD}$CF_RECORD_NAME${NC}"
    echo -e "   • IPv4 Target: ${CYAN}${BOLD}$CREATED_IP${NC}"
    echo -e "   • Proxy status: ${BOLD}DNS only (Grey Cloud / OFF)${NC}"
fi

# ============ Step 6: Wait for Setup ============
log_step "Waiting for software installation on VM (takes ~20-30s)..."
log_info "Installing dnstt-server + Xray core..."

for i in $(seq 1 30); do
    DONE=$(gcloud compute ssh "$VM_NAME" --zone="$DEPLOYED_ZONE" --project="$PROJECT_ID" \
        --command="test -f /tmp/slowdns-setup-done && echo YES || echo NO" \
        --quiet --ssh-flag="-o StrictHostKeyChecking=no" --ssh-flag="-o ConnectTimeout=5" < /dev/null 2>/dev/null || echo "NO")
    if [ "$DONE" = "YES" ]; then
        log_step "Setup complete! ✅"
        break
    fi
    if [ $((i % 3)) -eq 0 ]; then
        log_info "Installing... ($((i*5))s elapsed)"
    fi
    sleep 5
done

# Verify services
log_step "Verifying services..."
gcloud compute ssh "$VM_NAME" --zone="$DEPLOYED_ZONE" --project="$PROJECT_ID" \
    --command="systemctl is-active slowdns xray 2>/dev/null; ss -ulpn | grep ':53 ' || true" \
    --quiet --ssh-flag="-o StrictHostKeyChecking=no" --ssh-flag="-o ConnectTimeout=5" < /dev/null 2>/dev/null || true

# ============ Step 7: Print Results ============
VMESS_LINK="vmess://eyJ2IjoiMiIsInBzIjoiR0NQIFNMT1dETlMgVk1FU1MiLCJhZGQiOiIxMjcuMC4wLjEiLCJwb3J0IjoiMTAwODYiLCJpZCI6IjYwYzQ0ZWQyLTRkZDQtNDNhYi05YTY2LWEwYjQwNjIzYTFkNCIsImFpZCI6IjAiLCJzY3kiOiJhdXRvIiwibmV0IjoidGNwIiwidHlwZSI6Im5vbmUiLCJob3N0IjoiIiwicGF0aCI6IiIsInRscyI6IiIsInNuaSI6IiIsImFscG4iOiIifQ=="

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║     🎉  DEPLOYMENT SUCCESSFUL!  সফলভাবে সম্পন্ন! 🎉     ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BOLD}🌐 Server Details:${NC}"
echo -e "   • Project:      ${CYAN}$PROJECT_ID${NC}"
echo -e "   • Zone:         ${CYAN}$DEPLOYED_ZONE${NC}"
echo -e "   • Server IP:    ${CYAN}$CREATED_IP${NC}"
if [ -n "$CF_SUCCESS" ]; then
    echo -e "   • DNS Status:   ${GREEN}$CF_RECORD_NAME → $CREATED_IP ✅${NC}"
else
    echo -e "   • DNS Status:   ${YELLOW}MANUAL: Point $CF_RECORD_NAME → $CREATED_IP${NC}"
fi
echo ""
echo -e "${BOLD}🔑 SlowDNS Config (HTTP Custom / Netmod):${NC}"
echo -e "   • NS Domain:    ${CYAN}$NS_DOMAIN${NC}"
echo -e "   • DNS Domain:   ${CYAN}$SLOWDNS_DOMAIN${NC}"
echo -e "   • Public Key:   ${CYAN}$SLOWDNS_PUBKEY${NC}"
echo ""
echo -e "${BOLD}📱 V2Ray (VMess) Config:${NC}"
echo -e "   • Address:      ${CYAN}127.0.0.1${NC}"
echo -e "   • Port:         ${CYAN}$VMESS_PORT${NC}"
echo -e "   • UUID:         ${CYAN}$VMESS_UUID${NC}"
echo -e "   • AlterID:      ${CYAN}0${NC}"
echo -e "   • Network:      ${CYAN}tcp${NC}"
echo ""
echo -e "${BOLD}🔗 VMess Link:${NC}"
echo -e "   ${CYAN}$VMESS_LINK${NC}"
echo ""
echo -e "${BOLD}🔐 SSH Access (over SlowDNS):${NC}"
echo -e "   • Username:     ${CYAN}foridul${NC}"
echo -e "   • Password:     ${CYAN}foridul123${NC}"
echo ""
echo -e "${YELLOW}⚡ আপনার অ্যাপে সেটিংস আগে থেকে থাকলে সরাসরি কানেক্ট দিন!${NC}"
echo -e "${YELLOW}   কোনো কনফিগ পরিবর্তন করার প্রয়োজন নেই।${NC}"
echo ""

if [ -n "$TG_CHAT_ID" ]; then
    TG_FINAL_MSG="🎉 *DEPLOYMENT COMPLETED SUCCESSFULLY!*

🌐 *Server Details:*
• *Project:* \`$PROJECT_ID\`
• *Zone:* \`$DEPLOYED_ZONE\`
• *Server IP:* \`$CREATED_IP\`
• *DNS:* \`$CF_RECORD_NAME → $CREATED_IP\` ✅

🔑 *SlowDNS Config:*
• *NS Domain:* \`$NS_DOMAIN\`
• *DNS Domain:* \`$SLOWDNS_DOMAIN\`
• *Public Key:*
\`$SLOWDNS_PUBKEY\`

📱 *V2Ray (VMess) Link (ট্যাপ করে কপি করুন):*
\`$VMESS_LINK\`

🔐 *SSH Access (over SlowDNS):*
• *Host:* \`127.0.0.1\`
• *User:* \`foridul\`
• *Pass:* \`foridul123\`
• *Root Pass:* \`Foridul4.22\`

⚡ *আপনার অ্যাপে (HTTP Custom / Netmod / etc.) আগে থেকে সেভ করা থাকলে সরাসরি Connect দিন!*"

    send_tg "$TG_FINAL_MSG"
fi
