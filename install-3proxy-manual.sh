#!/bin/bash
#
# 🔒 Manual 3proxy Installer (Quick Fix)
# Install 3proxy dari source dengan git clone
# Jalankan script ini DI VM target (bukan remote)
#
# Usage: ./install-3proxy-manual.sh [USERNAME] [PASSWORD]
# Example: ./install-3proxy-manual.sh admin password123
#

set -e

PROXY_USER=${1:-admin}
PROXY_PASS=${2:-$(openssl rand -base64 12)}

echo "🔧 Manual 3proxy Installation"
echo "   Username: $PROXY_USER"
echo "   Password: $PROXY_PASS"
echo ""

# Get current IP
CURRENT_IP=$(hostname -I | awk '{print $1}' || echo "unknown")
echo "📍 Server IP: $CURRENT_IP"
echo ""

# Install dependencies
echo "📦 Installing dependencies..."
apt update -qq
apt install -y git gcc make libc6-dev wget

# Download & build 3proxy
echo "📦 Downloading 3proxy source from GitHub..."
cd /tmp
rm -rf 3proxy* 2>/dev/null || true

# Try multiple download methods
DOWNLOAD_SUCCESS=false

# Method 1: Try official source (3proxy.org) - most reliable
echo "   Method 1: Downloading from 3proxy.org..."
if wget --timeout=15 -O 3proxy-0.9.4.tgz http://3proxy.org/0.9.4/3proxy-0.9.4.tgz 2>&1 | grep -q "saved"; then
    FILE_SIZE=$(stat -c%s 3proxy-0.9.4.tgz 2>/dev/null || echo 0)
    if [ "$FILE_SIZE" -gt 500000 ]; then  # At least 500KB
        echo "   ✅ Download successful from 3proxy.org"
        if tar -xzf 3proxy-0.9.4.tgz 2>&1; then
            cd 3proxy-0.9.4
            DOWNLOAD_SUCCESS=true
        fi
    fi
fi

# Method 2: Try GitHub repository (correct URL)
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

# Method 3: Try GitHub tarball
if [ "$DOWNLOAD_SUCCESS" = false ]; then
    echo "   Method 3: Trying GitHub tarball..."
    rm -rf 3proxy* 2>/dev/null || true
    
    for url in \
        "https://github.com/3proxy/3proxy/archive/refs/heads/master.tar.gz" \
        "https://github.com/3proxy/3proxy/archive/refs/heads/0.9.4.tar.gz"; do
        echo "   Trying: $(basename $url)"
        if wget --timeout=15 -O 3proxy.tar.gz "$url" 2>&1 | grep -q "saved"; then
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
    echo "   2. Upload to VM: scp 3proxy-0.9.4.tgz root@103.163.111.44:/tmp/"
    echo "   3. Then run: cd /tmp && tar -xzf 3proxy-0.9.4.tgz && cd 3proxy-0.9.4"
    echo "   4. Build: make -f Makefile.Linux && cp bin/3proxy /usr/local/bin/"
    exit 1
fi

echo "📦 Building 3proxy..."
if make -f Makefile.Linux 2>&1; then
    echo "   ✅ Build successful"
else
    echo "   ❌ Build failed"
    exit 1
fi

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
    echo "   ✅ 3proxy is working!"
else
    echo "   ⚠️  Binary exists but test failed (might be normal)"
fi

# Setup config
echo "📝 Creating config directory..."
mkdir -p /etc/3proxy
mkdir -p /var/log/3proxy

echo "📝 Writing 3proxy config..."
cat > /etc/3proxy/3proxy.cfg << EOF
# 3proxy configuration for SOCKS5
# Generated automatically

# Run as daemon
daemon

# Connection limits
maxconn 100

# Authentication
auth strong
users $PROXY_USER:CL:$PROXY_PASS

# ACL Rules (MUST come BEFORE logging commands)
allow $PROXY_USER 103.163.111.46 * * 80,443,8080,1080
allow $PROXY_USER 127.0.0.1 * * 80,443,8080,1080

# Logging (MUST come AFTER allow/deny)
nolog
log /var/log/3proxy/3proxy.log D
logformat "- %U %C:%c %R:%r %O %I %h %T"

# SOCKS5 proxy on port 1080
socks -p1080

# Deny all other connections (MUST be last)
deny *
EOF

echo "🔒 Setting permissions..."
chmod 600 /etc/3proxy/3proxy.cfg
chown root:root /etc/3proxy/3proxy.cfg

# Create systemd service
echo "📝 Creating systemd service..."
cat > /etc/systemd/system/3proxy.service << 'EOFSERVICE'
[Unit]
Description=3proxy Proxy Server
After=network.target

[Service]
Type=forking
ExecStart=/usr/local/bin/3proxy /etc/3proxy/3proxy.cfg
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOFSERVICE

systemctl daemon-reload

# Start service
echo "🔄 Starting 3proxy service..."
systemctl enable 3proxy
systemctl restart 3proxy

sleep 2

# Check status
echo "✅ Checking service status..."
if systemctl is-active --quiet 3proxy 2>/dev/null || pgrep -x 3proxy > /dev/null; then
    echo "   ✅ 3proxy is running!"
    systemctl status 3proxy --no-pager -l | head -10
else
    echo "   ⚠️  Service might not be running, checking..."
    systemctl status 3proxy --no-pager -l || true
fi

# Test proxy
echo "🔍 Testing proxy locally..."
sleep 2
TEST_IP=$(curl -s --socks5 $PROXY_USER:$PROXY_PASS@127.0.0.1:1080 https://api.ipify.org 2>/dev/null || echo "FAILED")

if [ "$TEST_IP" != "FAILED" ] && [ -n "$TEST_IP" ]; then
    echo "   ✅ Proxy test: OK (IP: $TEST_IP)"
else
    echo "   ⚠️  Local test failed (might need external test from platform VM)"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Installation Complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "📋 Proxy Information:"
echo "   Address: $CURRENT_IP"
echo "   Port: 1080"
echo "   Username: $PROXY_USER"
echo "   Password: $PROXY_PASS"
echo "   URL: socks5://$PROXY_USER:$PROXY_PASS@$CURRENT_IP:1080"
echo ""
echo "🔍 To test from platform VM (103.163.111.46):"
echo "   curl --socks5 $PROXY_USER:$PROXY_PASS@$CURRENT_IP:1080 https://api.ipify.org"
echo ""
echo "🔧 Useful commands:"
echo "   systemctl status 3proxy"
echo "   systemctl restart 3proxy"
echo "   tail -f /var/log/3proxy/3proxy.log"
echo ""

