#!/bin/bash
#
# 🚀 Automated Proxy Installation untuk Semua IP Gasnet
# Install proxy di semua IP sekaligus dengan satu command
#
# Usage: 
#   bash install-all-proxies-automated.sh [PROXY_USERNAME] [PROXY_PASSWORD] [SSH_PASSWORD]
#
# Example:
#   bash install-all-proxies-automated.sh admin password123
#   bash install-all-proxies-automated.sh admin password123 rootpassword  # With SSH password
#

set -e

PROXY_USER=${1:-admin}
PROXY_PASS=${2:-$(openssl rand -base64 12)}
SSH_PASSWORD=${3:-""}  # Optional SSH password for password authentication
PLATFORM_IP="103.163.111.46"

# Check if sshpass is available (for password authentication)
USE_SSHPASS=false
if [ -n "$SSH_PASSWORD" ] && command -v sshpass &> /dev/null; then
    USE_SSHPASS=true
    echo "🔑 Using sshpass for password authentication"
elif [ -n "$SSH_PASSWORD" ] && ! command -v sshpass &> /dev/null; then
    echo "⚠️  sshpass not found. Installing..."
    if command -v apt-get &> /dev/null; then
        apt-get update && apt-get install -y sshpass
        USE_SSHPASS=true
    elif command -v yum &> /dev/null; then
        yum install -y sshpass
        USE_SSHPASS=true
    else
        echo "❌ Cannot install sshpass automatically. Please install manually:"
        echo "   apt-get install sshpass  # Debian/Ubuntu"
        echo "   yum install sshpass      # CentOS/RHEL"
        echo ""
        echo "💡 Or setup SSH key first: ssh-copy-id root@<IP>"
        USE_SSHPASS=false
    fi
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🚀 Automated Proxy Installation"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "📋 Configuration:"
echo "   Username: $PROXY_USER"
echo "   Password: $PROXY_PASS"
echo "   Platform IP: $PLATFORM_IP"
echo ""

# List of IP addresses (skip platform IP dan Proxmox)
# ✅ Updated: IP list sesuai dengan VM yang tersedia
IPS=(
    "103.163.111.43"
    "103.163.111.41"
    "103.163.111.42"
    "103.163.111.44"
    "103.163.111.45"
    "103.163.111.98"
)

# Skip IP:
# - 103.163.111.46 (platform IP - VM utama wablash, JANGAN install proxy di sini!)
# - 103.163.111.132 (Proxmox hypervisor - JANGAN install proxy di sini!)
SKIP_IPS=("103.163.111.46" "103.163.111.132")

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SCRIPT="$SCRIPT_DIR/install-proxy-robust.sh"

if [ ! -f "$INSTALL_SCRIPT" ]; then
    echo "❌ Install script not found: $INSTALL_SCRIPT"
    exit 1
fi

echo "📁 Install script: $INSTALL_SCRIPT"
echo ""

# Get current server IP (where script is running)
CURRENT_SERVER_IP=$(hostname -I | awk '{print $1}' 2>/dev/null || ip addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -1 || echo "")
if [ -z "$CURRENT_SERVER_IP" ]; then
    # Try alternative method
    CURRENT_SERVER_IP=$(curl -s ifconfig.me 2>/dev/null || echo "")
fi
echo "📍 Current server IP: ${CURRENT_SERVER_IP:-unknown}"
echo ""

# Store proxy list for later use
PROXY_LIST_FILE="./gasnet-proxy-list.txt"
echo "# Gasnet SOCKS5 Proxy List" > $PROXY_LIST_FILE
echo "# Generated: $(date)" >> $PROXY_LIST_FILE
echo "# Username: $PROXY_USER" >> $PROXY_LIST_FILE
echo "" >> $PROXY_LIST_FILE

SUCCESS_COUNT=0
FAILED_COUNT=0
SKIP_COUNT=0
FAILED_IPS=()

for IP in "${IPS[@]}"; do
    # Skip if in skip list
    SKIP_THIS=false
    for SKIP_IP in "${SKIP_IPS[@]}"; do
        if [ "$IP" = "$SKIP_IP" ]; then
            SKIP_THIS=true
            break
        fi
    done
    
    # ✅ CRITICAL FIX: Skip current server IP (install locally instead of via SSH)
    if [ -n "$CURRENT_SERVER_IP" ] && [ "$IP" = "$CURRENT_SERVER_IP" ]; then
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "📍 Installing proxy locally on $IP (current server)..."
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        
        # Install directly on current server (no SSH needed)
        if bash "$INSTALL_SCRIPT" "$PROXY_USER" "$PROXY_PASS" "$PLATFORM_IP" 2>&1; then
            echo "✅ Success: $IP (local installation)"
            echo "socks5://$PROXY_USER:$PROXY_PASS@$IP:1080" >> $PROXY_LIST_FILE
            ((SUCCESS_COUNT++))
        else
            echo "❌ Failed: $IP (local installation)"
            ((FAILED_COUNT++))
            FAILED_IPS+=("$IP")
        fi
        echo ""
        continue
    fi
    
    if [ "$SKIP_THIS" = true ]; then
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "⏭️  Skipping $IP (already installed or platform)"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        ((SKIP_COUNT++))
        continue
    fi
    
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "📡 Installing proxy on $IP..."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    # Check if SSH access is available
    echo "🔍 Checking SSH connection to $IP..."
    SSH_CONNECTED=false
    USE_PASSWORD_AUTH=false
    
    # Try SSH key first (BatchMode)
    if timeout 10 ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o BatchMode=yes root@$IP "echo 'Connected'" 2>/dev/null; then
        SSH_CONNECTED=true
        USE_PASSWORD_AUTH=false
        echo "✅ SSH connection OK (using SSH key)"
    # Try password authentication if provided
    elif [ "$USE_SSHPASS" = true ] && [ -n "$SSH_PASSWORD" ]; then
        echo "🔑 Trying password authentication..."
        if sshpass -p "$SSH_PASSWORD" ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no root@$IP "echo 'Connected'" 2>/dev/null; then
            SSH_CONNECTED=true
            USE_PASSWORD_AUTH=true
            echo "✅ SSH connection OK (using password)"
        fi
    fi
    
    if [ "$SSH_CONNECTED" = false ]; then
        echo "❌ Cannot connect to $IP via SSH"
        echo "   Please ensure:"
        echo "   - SSH access is configured"
        echo "   - SSH key is added: ssh-copy-id root@$IP"
        if [ -z "$SSH_PASSWORD" ]; then
            echo "   - Or provide SSH password: bash install-all-proxies-automated.sh $PROXY_USER $PROXY_PASS <SSH_PASSWORD>"
        fi
        echo "   - You have root access"
        echo "   - Firewall allows SSH connections (port 22)"
        echo ""
        echo "💡 Setup SSH key untuk IP ini:"
        echo "   ssh-copy-id root@$IP"
        echo "   # Atau test manual: ssh root@$IP"
        echo ""
        echo "💡 Skip IP ini dan lanjut ke IP berikutnya..."
        echo ""
        ((FAILED_COUNT++))
        FAILED_IPS+=("$IP")
        continue
    fi
    
    # Copy install script to remote server
    echo "📤 Copying install script to $IP..."
    if [ "$USE_PASSWORD_AUTH" = true ]; then
        # Use sshpass for password authentication
        if ! sshpass -p "$SSH_PASSWORD" scp -o StrictHostKeyChecking=no "$INSTALL_SCRIPT" root@$IP:/tmp/install-proxy-robust.sh 2>/dev/null; then
            echo "❌ Failed to copy script to $IP"
            ((FAILED_COUNT++))
            FAILED_IPS+=("$IP")
            continue
        fi
    else
        # Use SSH key
        if ! scp -o StrictHostKeyChecking=no "$INSTALL_SCRIPT" root@$IP:/tmp/install-proxy-robust.sh 2>/dev/null; then
            echo "❌ Failed to copy script to $IP"
            ((FAILED_COUNT++))
            FAILED_IPS+=("$IP")
            continue
        fi
    fi
    
    # Run install script on remote server
    echo "🚀 Running installation on $IP..."
    if [ "$USE_PASSWORD_AUTH" = true ]; then
        # Use sshpass for password authentication
        if sshpass -p "$SSH_PASSWORD" ssh -o StrictHostKeyChecking=no root@$IP "chmod +x /tmp/install-proxy-robust.sh && bash /tmp/install-proxy-robust.sh $PROXY_USER $PROXY_PASS $PLATFORM_IP" 2>&1; then
            echo "✅ Success: $IP"
            echo "socks5://$PROXY_USER:$PROXY_PASS@$IP:1080" >> $PROXY_LIST_FILE
            ((SUCCESS_COUNT++))
        else
            echo "❌ Failed: $IP"
            ((FAILED_COUNT++))
            FAILED_IPS+=("$IP")
        fi
    else
        # Use SSH key
        if ssh -o StrictHostKeyChecking=no root@$IP "chmod +x /tmp/install-proxy-robust.sh && bash /tmp/install-proxy-robust.sh $PROXY_USER $PROXY_PASS $PLATFORM_IP" 2>&1; then
            echo "✅ Success: $IP"
            echo "socks5://$PROXY_USER:$PROXY_PASS@$IP:1080" >> $PROXY_LIST_FILE
            ((SUCCESS_COUNT++))
        else
            echo "❌ Failed: $IP"
            ((FAILED_COUNT++))
            FAILED_IPS+=("$IP")
        fi
    fi
    
    echo ""
    sleep 2
done

# Note: IP yang di-skip (platform dan Proxmox) tidak akan ditambahkan ke proxy list
# karena mereka bukan proxy server

# ✅ FIX: Tambahkan note untuk IP yang gagal
if [ $FAILED_COUNT -gt 0 ]; then
    echo "" >> $PROXY_LIST_FILE
    echo "# ⚠️ Failed to install (SSH connection issue):" >> $PROXY_LIST_FILE
    for FAILED_IP in "${FAILED_IPS[@]}"; do
        echo "# - $FAILED_IP" >> $PROXY_LIST_FILE
    done
    echo "#" >> $PROXY_LIST_FILE
    echo "# Setup SSH key untuk IP yang gagal:" >> $PROXY_LIST_FILE
    for FAILED_IP in "${FAILED_IPS[@]}"; do
        echo "#   ssh-copy-id root@$FAILED_IP" >> $PROXY_LIST_FILE
    done
    echo "#" >> $PROXY_LIST_FILE
    echo "# Atau install manual:" >> $PROXY_LIST_FILE
    echo "#   scp install-proxy-robust.sh root@<IP>:/tmp/" >> $PROXY_LIST_FILE
    echo "#   ssh root@<IP> 'bash /tmp/install-proxy-robust.sh $PROXY_USER $PROXY_PASS $PLATFORM_IP'" >> $PROXY_LIST_FILE
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📊 Installation Summary"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Success: $SUCCESS_COUNT"
echo "❌ Failed: $FAILED_COUNT"
echo "⏭️  Skipped: $SKIP_COUNT"
echo ""

if [ $SUCCESS_COUNT -gt 0 ]; then
    echo "📋 Proxy list saved to: $PROXY_LIST_FILE"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "📋 Complete Proxy List:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    cat $PROXY_LIST_FILE
    echo ""
    echo "💡 Copy proxy list di atas untuk PROXY_LIST di docker-compose.yml"
fi

