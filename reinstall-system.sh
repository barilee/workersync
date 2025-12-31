#!/bin/bash
# Download and run complete rebuild

# get URL from input or exit
if [ -z "$1" ]; then
    echo "Usage: $0 <git-repo-url>"
    exit 1
fi

URL="$1"

echo "Downloading latest rebuild script..."
git clone $URL /tmp/worker-sync-temp
chmod +x /tmp/worker-sync-temp/master-rebuild.sh

echo "Please edit configuration..."
nano /tmp/worker-sync-temp/master-rebuild.sh

echo "Running rebuild..."
sudo /tmp/worker-sync-temp/master-rebuild.sh