#!/bin/bash
#
# 🔒 Robust 3proxy Installer - One-Time Install
# Fix semua masalah yang sudah terjadi sebelumnya:
# - Config format error (nolog conflict) ✅
# - Allow format error (port dengan koma) ✅
# - Service type error (forking) ✅
#
# Usage: sudo bash install-proxy-robust.sh [USERNAME] [PASSWORD] [PLATFORM_IP]
# Example: sudo bash install-proxy-robust.sh admin password123 103.163.111.46
#
# Jika tidak specify username/password, akan generate random password
# Jika tidak specify PLATFORM_IP, akan auto-detect dari current connection
#

set -e

PROXY_USER=${1:-admin}
PROXY_PASS=${2:-$(openssl rand -base64 12)}
PLATFORM_IP=${3:-"103.163.111.46"}  # Default platform VM IP

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔒 Robust 3proxy Installation"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "📋 Configuration:"
echo "   Username: $PROXY_USER"
echo "   Password: $PROXY_PASS"
echo "   Platform IP: $PLATFORM_IP"
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo "❌ Script harus dijalankan sebagai root (sudo)"
    echo ""
    echo "💡 Jalankan dengan:"
    echo "   sudo bash install-proxy-robust.sh $PROXY_USER $PROXY_PASS $PLATFORM_IP"
    exit 1
fi

# Get current IP (try multiple methods)
CURRENT_IP=""
if command -v hostname >/dev/null 2>&1; then
    CURRENT_IP=$(hostname -I 2>/dev/null | awk '{print $1}' | grep -v '^$' || echo "")
fi
if [ -z "$CURRENT_IP" ]; then
    CURRENT_IP=$(ip addr show 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -1 || echo "")
fi
if [ -z "$CURRENT_IP" ]; then
    CURRENT_IP=$(curl -s --connect-timeout 3 https://api.ipify.org 2>/dev/null || echo "")
fi
if [ -z "$CURRENT_IP" ]; then
    echo "⚠️  Warning: Could not detect server IP automatically"
    echo "   Please specify IP manually or check network configuration"
    CURRENT_IP="unknown"
fi
echo "📍 Server IP: $CURRENT_IP"
echo ""

# Stop and cleanup existing 3proxy if any
echo "🧹 Cleaning up existing 3proxy..."
systemctl stop 3proxy 2>/dev/null || true
pkill -9 3proxy 2>/dev/null || true
systemctl disable 3proxy 2>/dev/null || true

# Install dependencies
echo "📦 Installing dependencies..."

# ✅ FIX: Disable problematic repositories before update
if [ -f /etc/apt/sources.list.d/php.list ]; then
    echo "   ⚠️  Found PHP repository, temporarily disabling to avoid errors..."
    mv /etc/apt/sources.list.d/php.list /etc/apt/sources.list.d/php.list.disabled 2>/dev/null || true
fi

# ✅ FIX: Handle repository errors gracefully (skip invalid repositories)
# Use --allow-releaseinfo-change to skip invalid repositories
if DEBIAN_FRONTEND=noninteractive apt update --allow-releaseinfo-change -qq 2>&1 | grep -v "I'm a teapot\|not signed\|Failed to fetch" >/dev/null 2>&1; then
    echo "   ✅ Repository update successful"
else
    # If --allow-releaseinfo-change not supported, try regular update
    echo "   ⚠️  Repository update had some errors, continuing anyway..."
    DEBIAN_FRONTEND=noninteractive apt update -qq 2>&1 | grep -v "I'm a teapot\|not signed\|Failed to fetch" >/dev/null 2>&1 || true
fi

# ✅ FIX: Install dependencies (these are standard packages, should work even with repo errors)
echo "   Installing: git gcc make libc6-dev wget curl openssl..."
if DEBIAN_FRONTEND=noninteractive apt install -y git gcc make libc6-dev wget curl openssl >/dev/null 2>&1; then
    echo "   ✅ Dependencies installed successfully"
else
    # Try again with error output visible for debugging
    echo "   ⚠️  First attempt failed, trying again with verbose output..."
    if ! DEBIAN_FRONTEND=noninteractive apt install -y git gcc make libc6-dev wget curl openssl 2>&1 | grep -v "I'm a teapot\|not signed"; then
        echo "❌ Failed to install dependencies"
        echo ""
        echo "💡 Troubleshooting:"
        echo "   1. Check repository configuration: cat /etc/apt/sources.list"
        echo "   2. Remove invalid repositories:"
        echo "      sudo rm -f /etc/apt/sources.list.d/php.list"
        echo "      sudo apt update"
        echo "   3. Or install manually:"
        echo "      sudo apt-get install git gcc make libc6-dev wget curl openssl"
        exit 1
    fi
    echo "   ✅ Dependencies installed successfully"
fi

# Download & build 3proxy
echo "📦 Downloading 3proxy source..."
cd /tmp
rm -rf 3proxy* 2>/dev/null || true

DOWNLOAD_SUCCESS=false

# Method 1: Official 3proxy.org (most reliable)
echo "   Method 1: Downloading from 3proxy.org..."
if wget --timeout=20 -O 3proxy-0.9.4.tgz http://3proxy.org/0.9.4/3proxy-0.9.4.tgz 2>&1 | grep -q "saved"; then
    FILE_SIZE=$(stat -c%s 3proxy-0.9.4.tgz 2>/dev/null || echo 0)
    if [ "$FILE_SIZE" -gt 500000 ]; then
        echo "   ✅ Download successful from 3proxy.org"
        if tar -xzf 3proxy-0.9.4.tgz 2>&1; then
            cd 3proxy-0.9.4
            DOWNLOAD_SUCCESS=true
        fi
    fi
fi

# Method 2: GitHub clone
if [ "$DOWNLOAD_SUCCESS" = false ]; then
    echo "   Method 2: Trying GitHub clone..."
    rm -rf 3proxy* 2>/dev/null || true
    
    if git clone --depth 1 https://github.com/3proxy/3proxy.git 2>&1 | grep -qv "Authentication\|not found\|fatal"; then
        if [ -d 3proxy ]; then
            cd 3proxy
            DOWNLOAD_SUCCESS=true
            echo "   ✅ Git clone successful"
        fi
    fi
fi

# Method 3: GitHub tarball
if [ "$DOWNLOAD_SUCCESS" = false ]; then
    echo "   Method 3: Trying GitHub tarball..."
    rm -rf 3proxy* 2>/dev/null || true
    
    for url in \
        "https://github.com/3proxy/3proxy/archive/refs/heads/master.tar.gz" \
        "https://github.com/3proxy/3proxy/archive/refs/heads/0.9.4.tar.gz"; do
        echo "   Trying: $(basename $url)"
        if wget --timeout=20 -O 3proxy.tar.gz "$url" 2>&1 | grep -q "saved"; then
            FILE_SIZE=$(stat -c%s 3proxy.tar.gz 2>/dev/null || echo 0)
            if [ "$FILE_SIZE" -gt 500000 ]; then
                if tar -xzf 3proxy.tar.gz 2>&1; then
                    cd 3proxy-* 2>/dev/null
                    DOWNLOAD_SUCCESS=true
                    echo "   ✅ Download successful"
                    break
                fi
            fi
        fi
        rm -f 3proxy.tar.gz 2>/dev/null || true
    done
fi

if [ "$DOWNLOAD_SUCCESS" = false ]; then
    echo "   ❌ All download methods failed"
    echo ""
    echo "💡 Manual download instructions:"
    echo "   1. Download from: http://3proxy.org/0.9.4/3proxy-0.9.4.tgz"
    echo "   2. Upload to VM: scp 3proxy-0.9.4.tgz root@$CURRENT_IP:/tmp/"
    echo "   3. Then run: cd /tmp && tar -xzf 3proxy-0.9.4.tgz && cd 3proxy-0.9.4"
    echo "   4. Build: make -f Makefile.Linux && cp bin/3proxy /usr/local/bin/"
    exit 1
fi

# Build 3proxy
echo "📦 Building 3proxy..."
if ! make -f Makefile.Linux 2>&1; then
    echo "   ❌ Build failed"
    exit 1
fi

echo "   ✅ Build successful"

# Install binary
echo "📦 Installing binary..."
mkdir -p /usr/local/bin
if [ -f bin/3proxy ]; then
    cp bin/3proxy /usr/local/bin/
    chmod +x /usr/local/bin/3proxy
    echo "   ✅ Binary installed to /usr/local/bin/3proxy"
else
    echo "   ❌ Binary not found after build"
    exit 1
fi

# Verify installation
echo "🔍 Verifying installation..."
if /usr/local/bin/3proxy -h >/dev/null 2>&1; then
    echo "   ✅ 3proxy binary is working!"
else
    echo "   ⚠️  Binary exists but test failed (might be normal)"
fi

# Setup directories
echo "📝 Creating directories..."
mkdir -p /etc/3proxy
mkdir -p /var/log/3proxy
chmod 755 /var/log/3proxy

# ✅ FIX: Write correct config format (based on all issues fixed)
echo "📝 Writing 3proxy config (FIXED FORMAT)..."
cat > /tmp/3proxy.cfg.new << EOF
# 3proxy configuration for SOCKS5
# Generated automatically - FIXED FORMAT (no errors)

# Run as daemon
daemon

# Connection limits
maxconn 100

# Authentication
auth strong
users $PROXY_USER:CL:$PROXY_PASS

# ACL Rules (MUST come BEFORE logging commands)
# ✅ FIX: Format allow tanpa port list (pakai * untuk semua port)
allow $PROXY_USER $PLATFORM_IP * *
allow $PROXY_USER 127.0.0.1 * *

# Logging (MUST come AFTER allow/deny)
# ✅ FIX: Hapus nolog yang konflik, pakai log saja
log /var/log/3proxy/3proxy.log D
logformat "- %U %C:%c %R:%r %O %I %h %T"

# SOCKS5 proxy on port 1080
socks -p1080

# Deny all other connections (MUST be last)
deny *
EOF

# Validate config syntax before replacing
echo "🔍 Validating config..."
if ! /usr/local/bin/3proxy -c /tmp/3proxy.cfg.new >/dev/null 2>&1; then
    echo "   ❌ Config validation failed:"
    /usr/local/bin/3proxy -c /tmp/3proxy.cfg.new 2>&1 || true
    exit 1
fi
echo "   ✅ Config syntax is valid"

# Backup old config if exists
if [ -f /etc/3proxy/3proxy.cfg ]; then
    cp /etc/3proxy/3proxy.cfg /etc/3proxy/3proxy.cfg.backup.$(date +%Y%m%d_%H%M%S)
fi

# Install config
mv /tmp/3proxy.cfg.new /etc/3proxy/3proxy.cfg
chmod 600 /etc/3proxy/3proxy.cfg
chown root:root /etc/3proxy/3proxy.cfg
echo "   ✅ Config file created and validated"

# ✅ FIX: Create systemd service with Type=simple (not forking)
echo "📝 Creating systemd service (FIXED TYPE)..."
cat > /etc/systemd/system/3proxy.service << 'EOFSERVICE'
[Unit]
Description=3proxy Proxy Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/3proxy /etc/3proxy/3proxy.cfg
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOFSERVICE

systemctl daemon-reload
echo "   ✅ Service file created (Type=simple)"

# Reset failed state if any
systemctl reset-failed 3proxy 2>/dev/null || true

# Start service
echo "🔄 Starting 3proxy service..."
systemctl enable 3proxy
systemctl start 3proxy

sleep 3

# Check status
echo "✅ Checking service status..."
if systemctl is-active --quiet 3proxy; then
    echo "   ✅ 3proxy service is ACTIVE"
else
    echo "   ❌ Service failed to start, checking logs..."
    journalctl -u 3proxy -n 20 --no-pager || true
    exit 1
fi

# Check port
echo "🔍 Checking port 1080..."
sleep 2
if netstat -tlnp 2>/dev/null | grep -q ":1080" || ss -tlnp 2>/dev/null | grep -q ":1080"; then
    PORT_STATUS=$(netstat -tlnp 2>/dev/null | grep ":1080" || ss -tlnp 2>/dev/null | grep ":1080")
    echo "   ✅ Port 1080 is LISTENING"
    echo "   $PORT_STATUS" | head -1
else
    echo "   ⚠️  Port 1080 not listening yet, waiting..."
    sleep 3
    if netstat -tlnp 2>/dev/null | grep -q ":1080" || ss -tlnp 2>/dev/null | grep -q ":1080"; then
        echo "   ✅ Port 1080 is now LISTENING"
    else
        echo "   ❌ Port 1080 still not listening"
        echo "   Checking logs..."
        journalctl -u 3proxy -n 30 --no-pager || true
        exit 1
    fi
fi

# Setup firewall (if ufw is active)
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
    echo "🔥 Configuring firewall..."
    # Allow from platform IP
    ufw allow from $PLATFORM_IP to any port 1080 2>/dev/null || true
    # Allow from localhost for local testing
    ufw allow from 127.0.0.1 to any port 1080 2>/dev/null || true
    echo "   ✅ Firewall rules added for $PLATFORM_IP and localhost"
fi

# Test proxy locally (if curl is available)
echo "🔍 Testing proxy locally..."
sleep 2
if command -v curl >/dev/null 2>&1; then
    TEST_IP=$(curl -s --connect-timeout 5 --socks5 $PROXY_USER:$PROXY_PASS@127.0.0.1:1080 https://api.ipify.org 2>/dev/null || echo "FAILED")
    
    if [ "$TEST_IP" != "FAILED" ] && [ -n "$TEST_IP" ] && [ "$TEST_IP" != "unknown" ]; then
        echo "   ✅ Local proxy test: OK (IP: $TEST_IP)"
    else
        echo "   ⚠️  Local test failed (proxy might need external test from platform VM)"
        echo "   💡 Test manually: curl --socks5 $PROXY_USER:$PROXY_PASS@127.0.0.1:1080 https://api.ipify.org"
    fi
else
    echo "   ⚠️  curl not available, skipping local test"
    echo "   💡 Install curl or test from platform VM: curl --socks5 $PROXY_USER:$PROXY_PASS@$CURRENT_IP:1080 https://api.ipify.org"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ INSTALLATION COMPLETE!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "📋 Proxy Information:"
echo "   Address: $CURRENT_IP"
echo "   Port: 1080"
echo "   Username: $PROXY_USER"
echo "   Password: $PROXY_PASS"
echo "   URL: socks5://$PROXY_USER:$PROXY_PASS@$CURRENT_IP:1080"
echo ""
echo "🔍 To test from platform VM ($PLATFORM_IP):"
echo "   curl --socks5 $PROXY_USER:$PROXY_PASS@$CURRENT_IP:1080 https://api.ipify.org"
echo ""
echo "🔧 Useful commands:"
echo "   systemctl status 3proxy"
echo "   systemctl restart 3proxy"
echo "   tail -f /var/log/3proxy/3proxy.log"
echo ""

