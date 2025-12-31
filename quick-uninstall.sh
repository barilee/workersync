#!/bin/bash
# quick-uninstall.sh - Remove everything completely

echo "⚠️  WARNING: This will completely remove the freelancer system!"
read -p "Type 'DELETE' to confirm: " confirmation

if [ "$confirmation" != "DELETE" ]; then
    echo "Uninstall cancelled"
    exit 1
fi

# Stop and remove all Docker containers
docker compose -f /opt/freelancer-env/docker-compose.yml down 2>/dev/null || true
docker stop $(docker ps -aq) 2>/dev/null || true
docker rm $(docker ps -aq) 2>/dev/null || true

# Remove all Docker resources
docker system prune -a -f --volumes

# Remove project directory
rm -rf /opt/freelancer-env

# Remove Cloudflare DDNS
systemctl stop cloudflare-ddns.service cloudflare-ddns.timer 2>/dev/null || true
systemctl disable cloudflare-ddns.service cloudflare-ddns.timer 2>/dev/null || true
rm -rf /opt/cloudflare-ddns /etc/systemd/system/cloudflare-ddns.*

# Remove DuckDNS
systemctl stop duckdns.timer 2>/dev/null || true
systemctl disable duckdns.timer 2>/dev/null || true
rm -rf /opt/duckdns /etc/systemd/system/duckdns.*

# Reset firewall
ufw --force disable
ufw --force reset

echo "✅ System completely removed!"
echo "Run: sudo ./master-rebuild.sh to reinstall"