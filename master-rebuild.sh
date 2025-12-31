#!/bin/bash
# master-rebuild.sh - Complete Freelancer System Rebuild
# One script to rule them all - from cleanup to full deployment

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration - EDIT THESE VALUES
DOMAIN="freelancers.yourdomain.com"    # Your Cloudflare domain
CF_API_TOKEN=""                       # Your Cloudflare API Token
CF_ZONE_ID=""                         # Your Cloudflare Zone ID
SERVER_LOCAL_IP="192.168.1.100"       # Your server's local IP (for router config)
NUMBER_OF_FREELANCERS=3               # How many freelancer containers to create

# Global variables
PROJECT_DIR="/opt/freelancer-env"
PROJECT_PY_DIR="~/projects/py/master_rebuild"
SERVER_PUBLIC_IP=""
ADMIN_SSH_PORT=$((58080 + 5))  # Change 0 to offset if needed

# Function: Print colored output
print_status() {
    echo -e "${GREEN}[✓]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

print_error() {
    echo -e "${RED}[✗]${NC} $1"
}

print_step() {
    echo -e "${BLUE}[→]${NC} $1"
}

print_header() {
    echo -e "\n${MAGENTA}========================================${NC}"
    echo -e "${MAGENTA}   $1${NC}"
    echo -e "${MAGENTA}========================================${NC}\n"
}

# Function: Check if running as root/sudo
check_root() {
    if [ "$EUID" -ne 0 ]; then
        print_error "Please run as root or with sudo"
        exit 1
    fi
}

# Function: Get public IP
get_public_ip() {
    print_step "Detecting public IP address..."
    SERVER_PUBLIC_IP=$(curl -4 -s https://api.ipify.org 2>/dev/null || curl -4 -s https://checkip.amazonaws.com 2>/dev/null)
    if [ -z "$SERVER_PUBLIC_IP" ]; then
        SERVER_PUBLIC_IP="UNKNOWN"
        print_warning "Could not detect public IP"
    else
        print_status "Public IP: $SERVER_PUBLIC_IP"
    fi
}

# Function: Completely uninstall existing system
uninstall_existing() {
    print_header "STEP 1: UNINSTALLING EXISTING SYSTEM"
    
    print_step "Stopping and removing all Docker containers..."
    cd "$PROJECT_DIR" 2>/dev/null && docker compose down || true
    docker stop $(docker ps -aq) 2>/dev/null || true
    docker rm $(docker ps -aq) 2>/dev/null || true
    
    print_step "Removing Docker images..."
    docker rmi $(docker images -q) 2>/dev/null || true
    
    print_step "Removing Docker volumes..."
    docker volume rm $(docker volume ls -q) 2>/dev/null || true
    
    print_step "Removing Docker networks..."
    docker network rm $(docker network ls -q) 2>/dev/null || true
    
    print_step "Removing project directory..."
    rm -rf "$PROJECT_DIR" 2>/dev/null || true
    
    print_step "Removing Cloudflare DDNS..."
    systemctl stop cloudflare-ddns.service cloudflare-ddns.timer 2>/dev/null || true
    systemctl disable cloudflare-ddns.service cloudflare-ddns.timer 2>/dev/null || true
    rm -rf /opt/cloudflare-ddns 2>/dev/null || true
    rm -f /etc/systemd/system/cloudflare-ddns.* 2>/dev/null || true
    
    print_step "Removing DuckDNS (if exists)..."
    systemctl stop duckdns.timer 2>/dev/null || true
    systemctl disable duckdns.timer 2>/dev/null || true
    rm -rf /opt/duckdns 2>/dev/null || true
    rm -f /etc/systemd/system/duckdns.* 2>/dev/null || true
    
    print_step "Removing No-IP (if exists)..."
    systemctl stop noip 2>/dev/null || true
    systemctl disable noip 2>/dev/null || true
    rm -f /usr/local/bin/noip2 2>/dev/null || true
    
    print_step "Cleaning up Docker..."
    docker system prune -a -f --volumes 2>/dev/null || true
    
    print_status "Existing system completely removed!"
}

# Function: Install system dependencies
install_dependencies() {
    print_header "STEP 2: INSTALLING SYSTEM DEPENDENCIES"
    
    print_step "Updating package list..."
    apt update -y
    
    print_step "Installing Docker prerequisites..."
    apt install -y apt-transport-https ca-certificates curl software-properties-common gnupg lsb-release
    
    print_step "Adding Docker repository..."
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
    
    print_step "Installing Docker and Docker Compose..."
    apt update -y
    apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    
    print_step "Installing other dependencies..."
    apt install -y python3 python3-pip python3-venv jq net-tools ufw fail2ban cron
    
    print_step "Setting up Python virtual environment..."
    mkdir -p ${PROJECT_PY_DIR}
    cd ${PROJECT_PY_DIR}
    python3 -m venv .venv
    source .venv/bin/activate

    print_step "Installing Python packages..."
    pip3 install cryptography requests
    
    print_step "Starting and enabling Docker..."
    systemctl start docker
    systemctl enable docker
    
    print_step "Adding current user to docker group..."
    usermod -aG docker $SUDO_USER
    newgrp docker || true
    
    print_status "All dependencies installed!"
}

# Function: Setup firewall
setup_firewall() {
    print_header "STEP 3: CONFIGURING FIREWALL"
    
    print_step "Configuring UFW firewall..."
    ufw --force disable
    ufw --force reset
    
    # Default policies
    ufw default deny incoming
    ufw default allow outgoing
    
    # SSH
    ufw allow ssh
    
    # Admin SSH port
    ufw allow $ADMIN_SSH_PORT/tcp
    print_status "Allowed port: $ADMIN_SSH_PORT (Admin SSH)"

    # Freelancer ports
    for i in $(seq 1 $NUMBER_OF_FREELANCERS); do
        PORT=$((54040 + i))
        SSH_PORT=$((52520 + i))
        ufw allow $PORT/tcp
        ufw allow $SSH_PORT/tcp
        print_status "Allowed ports: $PORT (NoMachine), $SSH_PORT (SSH) for freelancer$i"
    done
    
    # Web ports (optional)
    ufw allow 80/tcp
    ufw allow 443/tcp
    
    # Enable firewall
    ufw --force enable
    
    print_step "Firewall status:"
    ufw status numbered
    
    print_status "Firewall configured!"
}

# Function: Setup Cloudflare DDNS
setup_cloudflare_ddns() {
    print_header "STEP 4: SETTING UP CLOUDFLARE DYNAMIC DNS"
    
    if [ -z "$CF_API_TOKEN" ] || [ -z "$CF_ZONE_ID" ]; then
        print_warning "Cloudflare API Token or Zone ID not set. Skipping DDNS setup."
        print_warning "Please manually update DNS records for: $DOMAIN → $SERVER_PUBLIC_IP"
        return 1
    fi
    
    print_step "Creating Cloudflare DDNS directory..."
    mkdir -p /opt/cloudflare-ddns
    
    cat > /opt/cloudflare-ddns/update.sh << 'EOF'
#!/bin/bash
# Cloudflare DDNS Update Script

CONFIG_FILE="/opt/cloudflare-ddns/config.json"
LOG_FILE="/opt/cloudflare-ddns/update.log"

# Load config
if [ ! -f "$CONFIG_FILE" ]; then
    echo "$(date): Config file not found" >> "$LOG_FILE"
    exit 1
fi

DOMAIN=$(jq -r '.domain' "$CONFIG_FILE")
ZONE_ID=$(jq -r '.zone_id' "$CONFIG_FILE")
API_TOKEN=$(jq -r '.api_token' "$CONFIG_FILE")

# Get current public IP
PUBLIC_IP=$(curl -4 -s https://api.ipify.org || curl -4 -s https://checkip.amazonaws.com)
if [ -z "$PUBLIC_IP" ]; then
    echo "$(date): Failed to get public IP" >> "$LOG_FILE"
    exit 1
fi

# Get existing DNS record
RECORD_INFO=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?type=A&name=$DOMAIN" \
  -H "Authorization: Bearer $API_TOKEN" \
  -H "Content-Type: application/json")

RECORD_ID=$(echo "$RECORD_INFO" | jq -r '.result[0].id // empty')
CURRENT_IP=$(echo "$RECORD_INFO" | jq -r '.result[0].content // empty')

if [ -z "$RECORD_ID" ]; then
    # Create new record
    echo "$(date): Creating new A record for $DOMAIN: $PUBLIC_IP" >> "$LOG_FILE"
    curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
      -H "Authorization: Bearer $API_TOKEN" \
      -H "Content-Type: application/json" \
      --data "{\"type\":\"A\",\"name\":\"$DOMAIN\",\"content\":\"$PUBLIC_IP\",\"ttl\":120,\"proxied\":false}" >> "$LOG_FILE" 2>&1
else
    # Update existing record
    if [ "$CURRENT_IP" != "$PUBLIC_IP" ]; then
        echo "$(date): Updating $DOMAIN: $CURRENT_IP → $PUBLIC_IP" >> "$LOG_FILE"
        curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RECORD_ID" \
          -H "Authorization: Bearer $API_TOKEN" \
          -H "Content-Type: application/json" \
          --data "{\"type\":\"A\",\"name\":\"$DOMAIN\",\"content\":\"$PUBLIC_IP\",\"ttl\":120,\"proxied\":false}" >> "$LOG_FILE" 2>&1
    else
        echo "$(date): IP unchanged: $PUBLIC_IP" >> "$LOG_FILE"
    fi
fi
EOF
    
    # Create config file
    cat > /opt/cloudflare-ddns/config.json << EOF
{
    "domain": "$DOMAIN",
    "zone_id": "$CF_ZONE_ID",
    "api_token": "$CF_API_TOKEN"
}
EOF
    
    # Create systemd service
    cat > /etc/systemd/system/cloudflare-ddns.service << EOF
[Unit]
Description=Cloudflare DDNS Update Service
After=network.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/opt/cloudflare-ddns/update.sh
User=root

[Install]
WantedBy=multi-user.target
EOF
    
    # Create systemd timer
    cat > /etc/systemd/system/cloudflare-ddns.timer << EOF
[Unit]
Description=Update Cloudflare DNS every 5 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min
RandomizedDelaySec=30

[Install]
WantedBy=timers.target
EOF
    
    # Set permissions
    chmod +x /opt/cloudflare-ddns/update.sh
    chmod 600 /opt/cloudflare-ddns/config.json
    
    # Start and enable
    systemctl daemon-reload
    systemctl enable cloudflare-ddns.timer
    systemctl start cloudflare-ddns.timer
    
    # Test once
    /opt/cloudflare-ddns/update.sh
    
    print_status "Cloudflare DDNS configured!"
    print_status "Domain: $DOMAIN"
    print_status "Will update every 5 minutes"
}

# Function: Create project structure
create_project_structure() {
    print_header "STEP 5: CREATING PROJECT STRUCTURE"
    
    print_step "Creating main project directory..."
    mkdir -p "$PROJECT_DIR"
    cd "$PROJECT_DIR"
    
    print_step "Creating subdirectories..."
    mkdir -p {dockerfiles,scripts,configs,data,backups,logs,nginx/{conf.d,ssl,html}}
    
    # Create data directories for each freelancer
    for i in $(seq 1 $NUMBER_OF_FREELANCERS); do
        mkdir -p "data/freelancer$i"
        mkdir -p "logs/freelancer$i"
    done
    
    print_status "Project structure created at: $PROJECT_DIR"
}

# Function: Create Dockerfile
create_dockerfile() {
    print_header "STEP 6: CREATING DOCKER CONTAINER CONFIGURATION"
    
    cat > "$PROJECT_DIR/dockerfiles/Dockerfile" << 'EOF'
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# Install NoMachine, XFCE, Chrome, and dependencies
RUN apt update && apt install -y \
    wget \
    gnupg \
    ca-certificates \
    curl \
    xfce4 \
    xfce4-goodies \
    xfce4-terminal \
    mousepad \
    firefox \
    python3 \
    python3-pip \
    sudo \
    openssh-server \
    net-tools \
    && rm -rf /var/lib/apt/lists/*

# Install Google Chrome
RUN wget -q -O - https://dl.google.com/linux/linux_signing_key.pub | gpg --dearmor -o /usr/share/keyrings/google-chrome-keyring.gpg \
    && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome-keyring.gpg] http://dl.google.com/linux/chrome/deb/ stable main" > /etc/apt/sources.list.d/google-chrome.list \
    && apt update && apt install -y google-chrome-stable \
    && rm -rf /var/lib/apt/lists/*

# Install NoMachine
RUN wget https://download.nomachine.com/download/8.10/Linux/nomachine_8.10.1_1_amd64.deb \
    && dpkg -i nomachine_8.10.1_1_amd64.deb || apt install -f -y \
    && rm nomachine_8.10.1_1_amd64.deb

# Install Python automation packages
RUN pip3 install selenium undetected_chromedriver cryptography

# Create freelancer user
RUN useradd -m -s /bin/bash freelancer && \
    echo "freelancer:freelancer123" | chpasswd && \
    usermod -aG sudo freelancer && \
    echo "freelancer ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# Set up NoMachine configuration
RUN mkdir -p /home/freelancer/.nx && \
    chown -R freelancer:freelancer /home/freelancer

# Create startup script
COPY startup.sh /usr/local/bin/startup.sh
RUN chmod +x /usr/local/bin/startup.sh

# Set XFCE as default session
RUN echo "xfce4-session" > /home/freelancer/.xsession

USER freelancer
WORKDIR /home/freelancer

EXPOSE 54040

CMD ["/usr/local/bin/startup.sh"]
EOF
    
    cat > "$PROJECT_DIR/dockerfiles/startup.sh" << 'EOF'
#!/bin/bash
# Container startup script

echo "=== Starting Freelancer Environment ==="
echo "Hostname: $(hostname)"
echo "Username: freelancer"
echo "Password: freelancer123"

# Start SSH
sudo service ssh start

# Configure NoMachine
sudo sed -i 's/#EnableNXSSH yes/EnableNXSSH yes/g' /usr/NX/etc/server.cfg
sudo sed -i 's/#AcceptPasswords yes/AcceptPasswords yes/g' /usr/NX/etc/server.cfg

# Start NoMachine
sudo /usr/NX/bin/nxserver --startup

# Wait for services
sleep 5

# Start automation script in background
python3 /scripts/auto_login.py &

# Keep container running
echo "=== Environment Ready ==="
echo "Connect via NoMachine on port 54040"
tail -f /dev/null
EOF
    
    chmod +x "$PROJECT_DIR/dockerfiles/startup.sh"
    
    print_status "Docker configuration created!"
}

# Function: Create docker-compose.yml
create_docker_compose() {
    print_header "STEP 7: CREATING DOCKER COMPOSE CONFIGURATION"
    
    cd "$PROJECT_DIR"
    
    cat > docker-compose.yml << EOF
version: '3.8'

services:
EOF

    # Generate service for each freelancer
    for i in $(seq 1 $NUMBER_OF_FREELANCERS); do
        NX_PORT=$((54040 + i))
        SSH_PORT=$((52520 + i))
        
        cat >> docker-compose.yml << EOF
  freelancer$i:
    build:
      context: ./dockerfiles
      dockerfile: Dockerfile
    container_name: freelancer$i
    hostname: freelancer$i
    environment:
      - FREELANCER_ID=freelancer$i
      - DISPLAY=:$((10 + i))
    volumes:
      - ./data/freelancer$i:/home/freelancer/data
      - ./scripts:/scripts:ro
      - ./configs:/configs:ro
      - ./logs/freelancer$i:/var/log/nomachine
      - /dev/shm:/dev/shm
    ports:
      - "$NX_PORT:54040"
      - "$SSH_PORT:22"
    cap_add:
      - SYS_ADMIN
      - NET_ADMIN
    shm_size: '2gb'
    stdin_open: true
    tty: true
    restart: unless-stopped
EOF
        print_status "Configured freelancer$i on ports $NX_PORT (NoMachine) and $SSH_PORT (SSH)"
    done
    
    cat >> docker-compose.yml << EOF

networks:
  default:
    driver: bridge
EOF
    
    print_status "Docker Compose configuration created for $NUMBER_OF_FREELANCERS freelancers"
}

# Function: Create automation script
create_automation_script() {
    print_header "STEP 8: CREATING AUTOMATION SCRIPTS"
    
    cat > "$PROJECT_DIR/scripts/auto_login.py" << 'EOF'
#!/usr/bin/env python3
"""
Automated login script for freelancer environments
Auto-logins to worksite and activity tracker
"""

import os
import time
import json
import sys
from pathlib import Path

# Add path for undetected_chromedriver
sys.path.insert(0, '/usr/local/lib/python3.10/dist-packages')

try:
    import undetected_chromedriver as uc
    from selenium.webdriver.common.by import By
    from selenium.webdriver.support.ui import WebDriverWait
    from selenium.webdriver.support import expected_conditions as EC
except ImportError:
    print("Installing required packages...")
    os.system("pip3 install selenium undetected_chromedriver")
    import undetected_chromedriver as uc
    from selenium.webdriver.common.by import By
    from selenium.webdriver.support.ui import WebDriverWait
    from selenium.webdriver.support import expected_conditions as EC

# Configuration
FREELANCER_ID = os.getenv('FREELANCER_ID', 'freelancer1')

class AutoLoginSystem:
    def __init__(self):
        self.driver = None
        self.config = self.load_config()
        
    def load_config(self):
        """Load configuration from file"""
        config_path = f"/configs/{FREELANCER_ID}.json"
        if os.path.exists(config_path):
            with open(config_path, 'r') as f:
                return json.load(f)
        
        # Default configuration template
        return {
            "worksite": {
                "url": "https://worksite.example.com/login",
                "username": "user@example.com",
                "password": "password123",
                "selectors": {
                    "username": "input[name='email'], input[name='username']",
                    "password": "input[type='password']",
                    "submit": "button[type='submit']"
                }
            },
            "tracker": {
                "url": "https://tracker.example.com",
                "username": "user",
                "password": "trackerpass"
            }
        }
    
    def setup_browser(self):
        """Setup Chrome with anti-detection"""
        print("Setting up Chrome browser...")
        
        options = uc.ChromeOptions()
        
        # Anti-detection settings
        options.add_argument('--disable-blink-features=AutomationControlled')
        options.add_argument('--no-sandbox')
        options.add_argument('--disable-dev-shm-usage')
        options.add_argument('--disable-gpu')
        options.add_argument('--window-size=1920,1080')
        options.add_argument('--start-maximized')
        
        # Profile directory
        profile_dir = f"/home/freelancer/.config/chrome-{FREELANCER_ID}"
        os.makedirs(profile_dir, exist_ok=True)
        options.add_argument(f'--user-data-dir={profile_dir}')
        
        # Disable location
        prefs = {
            "profile.default_content_setting_values.geolocation": 2,
            "profile.managed_default_content_settings.geolocation": 2
        }
        options.add_experimental_option("prefs", prefs)
        
        # Additional stealth
        options.add_experimental_option("excludeSwitches", ["enable-automation"])
        options.add_experimental_option('useAutomationExtension', False)
        
        self.driver = uc.Chrome(options=options)
        
        # Hide automation
        self.driver.execute_script("Object.defineProperty(navigator, 'webdriver', {get: () => undefined})")
        
        return True
    
    def login_to_worksite(self):
        """Automated login to worksite"""
        print(f"Logging into worksite: {self.config['worksite']['url']}")
        
        try:
            self.driver.get(self.config['worksite']['url'])
            time.sleep(3)
            
            # Find and fill username
            username_field = self.driver.find_element(By.CSS_SELECTOR, 
                self.config['worksite']['selectors']['username'])
            username_field.clear()
            username_field.send_keys(self.config['worksite']['username'])
            
            # Find and fill password
            password_field = self.driver.find_element(By.CSS_SELECTOR,
                self.config['worksite']['selectors']['password'])
            password_field.clear()
            password_field.send_keys(self.config['worksite']['password'])
            
            # Submit
            submit_button = self.driver.find_element(By.CSS_SELECTOR,
                self.config['worksite']['selectors']['submit'])
            submit_button.click()
            
            time.sleep(5)
            print("Worksite login successful")
            return True
            
        except Exception as e:
            print(f"Worksite login failed: {e}")
            return False
    
    def start_tracker(self):
        """Start activity tracker"""
        print("Starting activity tracker...")
        
        try:
            # Open tracker in new tab
            self.driver.execute_script("window.open('');")
            self.driver.switch_to.window(self.driver.window_handles[1])
            self.driver.get(self.config['tracker']['url'])
            time.sleep(3)
            
            print("Tracker opened in new tab")
            # Return to worksite tab
            self.driver.switch_to.window(self.driver.window_handles[0])
            
        except Exception as e:
            print(f"Tracker setup failed: {e}")
    
    def run(self):
        """Main execution"""
        print(f"=== Starting Auto-Login for {FREELANCER_ID} ===")
        
        if not self.setup_browser():
            print("Failed to setup browser")
            return
        
        if self.login_to_worksite():
            self.start_tracker()
            print("=== System Ready ===")
            print("Worksite: Auto-logged in")
            print("Tracker: Running in background")
            
            # Keep alive
            while True:
                time.sleep(60)
                # Prevent timeout
                self.driver.execute_script("window.scrollBy(0, 1)")
        else:
            print("Failed to initialize automation")
        
        self.driver.quit()

if __name__ == "__main__":
    automation = AutoLoginSystem()
    automation.run()
EOF
    
    # Create configuration template
    cat > "$PROJECT_DIR/scripts/create_config.py" << 'EOF'
#!/usr/bin/env python3
"""
Create freelancer configuration file
"""

import json
import sys
import os

def create_config(freelancer_id):
    config = {
        "worksite": {
            "url": input(f"Worksite URL for {freelancer_id}: "),
            "username": input(f"Worksite username/email: "),
            "password": input(f"Worksite password: "),
            "selectors": {
                "username": input("CSS selector for username field (e.g., input[name='email']): ") or "input[name='email']",
                "password": input("CSS selector for password field: ") or "input[type='password']",
                "submit": input("CSS selector for submit button: ") or "button[type='submit']"
            }
        },
        "tracker": {
            "url": input("Tracker URL: "),
            "username": input("Tracker username: "),
            "password": input("Tracker password: ")
        }
    }
    
    # Save to file
    config_path = f"../configs/{freelancer_id}.json"
    with open(config_path, 'w') as f:
        json.dump(config, f, indent=2)
    
    print(f"Configuration saved to {config_path}")
    print("IMPORTANT: Update the CSS selectors in auto_login.py if needed")

if __name__ == "__main__":
    if len(sys.argv) > 1:
        create_config(sys.argv[1])
    else:
        print("Usage: python3 create_config.py <freelancer_id>")
EOF
    
    # Create management script
    cat > "$PROJECT_DIR/manage.sh" << 'EOF'
#!/bin/bash
# Freelancer Management Script

PROJECT_DIR="/opt/freelancer-env"
DOMAIN="${DOMAIN:-freelancers.yourdomain.com}"

cd "$PROJECT_DIR" || { echo "Project directory not found"; exit 1; }

ACTION=$1
USER=$2

# Get public IP
get_ip() {
    curl -4 -s https://api.ipify.org 2>/dev/null || echo "UNKNOWN"
}

case $ACTION in
    start)
        if [ -z "$USER" ]; then
            echo "Starting all freelancers..."
            docker compose up -d
        else
            echo "Starting $USER..."
            docker compose up -d "$USER"
        fi
        
        echo ""
        echo "========================================"
        echo "   FREELANCER CONNECTION INFORMATION"
        echo "========================================"
        echo ""
        echo "🌐 Domain: $DOMAIN"
        echo "📡 Public IP: $(get_ip)"
        echo ""
        
        if [ -n "$USER" ]; then
            if [[ $USER =~ freelancer([0-9]+) ]]; then
                PORT=$((54040 + ${BASH_REMATCH[1]}))
                echo "👤 For $USER:"
                echo "   NoMachine: $DOMAIN:$PORT"
                echo "   Username: freelancer"
                echo "   Password: freelancer123"
            fi
        else
            echo "👥 All freelancers:"
            for i in {1..5}; do
                if docker ps --format "{{.Names}}" | grep -q "freelancer$i"; then
                    echo "   freelancer$i: $DOMAIN:$((54040 + i))"
                fi
            done
        fi
        
        echo ""
        echo "🔧 Test connection: nc -zv $DOMAIN $PORT"
        echo "========================================"
        ;;
    
    stop)
        if [ -z "$USER" ]; then
            docker compose down
        else
            docker compose stop "$USER"
        fi
        ;;
    
    restart)
        docker compose restart "$USER"
        ;;
    
    logs)
        docker compose logs -f "$USER"
        ;;
    
    status)
        echo "Container Status:"
        docker compose ps
        echo ""
        echo "Resource Usage:"
        docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}"
        ;;
    
    shell)
        docker exec -it "$USER" bash
        ;;
    
    backup)
        BACKUP_DIR="backups/$(date +%Y%m%d_%H%M%S)"
        mkdir -p "$BACKUP_DIR"
        docker compose stop
        cp -r data configs scripts "$BACKUP_DIR/"
        docker compose start
        echo "Backup created: $BACKUP_DIR"
        ;;
    
    config)
        echo "Creating configuration for new freelancer..."
        read -p "Freelancer ID (e.g., freelancer1): " fid
        python3 scripts/create_config.py "$fid"
        ;;
    
    update-dns)
        echo "Updating Cloudflare DNS..."
        /opt/cloudflare-ddns/update.sh
        ;;
    
    monitor)
        watch -n 5 "echo '=== FREELANCER SYSTEM ==='; echo ''; docker compose ps; echo ''; echo '=== RESOURCES ==='; docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}'"
        ;;
    
    *)
        echo "Usage: $0 {start|stop|restart|logs|status|shell|backup|config|update-dns|monitor} [freelancerX]"
        echo ""
        echo "Examples:"
        echo "  $0 start freelancer1    - Start single freelancer"
        echo "  $0 start                - Start all freelancers"
        echo "  $0 status               - Show status"
        echo "  $0 config               - Create config"
        echo "  $0 monitor              - Live monitor"
        echo ""
        echo "Domain: $DOMAIN"
        ;;
esac
EOF
    
    chmod +x "$PROJECT_DIR/scripts/auto_login.py"
    chmod +x "$PROJECT_DIR/scripts/create_config.py"
    chmod +x "$PROJECT_DIR/manage.sh"
    
    # Create simple configuration templates
    for i in $(seq 1 $NUMBER_OF_FREELANCERS); do
        cat > "$PROJECT_DIR/configs/freelancer$i.json" << EOF
{
  "worksite": {
    "url": "https://actual-worksite.com/login",
    "username": "freelancer$i@company.com",
    "password": "CHANGE_THIS_PASSWORD",
    "selectors": {
      "username": "input[name='email']",
      "password": "input[type='password']",
      "submit": "button[type='submit']"
    }
  },
  "tracker": {
    "url": "https://tracker.example.com",
    "username": "freelancer$i",
    "password": "CHANGE_TRACKER_PASSWORD"
  }
}
EOF
    done
    
    print_status "Automation scripts created!"
}

# Function: Build and start system
build_and_start() {
    print_header "STEP 9: BUILDING AND STARTING SYSTEM"
    
    cd "$PROJECT_DIR"
    
    print_step "Building Docker images (this may take a few minutes)..."
    docker compose build
    
    print_step "Starting all freelancer containers..."
    docker compose up -d
    
    print_step "Waiting for containers to start..."
    sleep 10
    
    print_step "Checking container status..."
    docker compose ps
    
    print_status "System built and started successfully!"
}

# Function: Create monitoring script
create_monitoring() {
    print_header "STEP 10: CREATING MONITORING SYSTEM"
    
    cat > "$PROJECT_DIR/monitor.sh" << 'EOF'
#!/bin/bash
# Real-time monitoring dashboard

DOMAIN="${DOMAIN:-freelancers.yourdomain.com}"

while true; do
    clear
    echo "┌─────────────────────────────────────────────────────┐"
    echo "│          FREELANCER MANAGEMENT SYSTEM               │"
    echo "│                 $(date +"%Y-%m-%d %H:%M:%S")                │"
    echo "└─────────────────────────────────────────────────────┘"
    echo ""
    
    # Get IP info
    PUBLIC_IP=$(curl -4 -s https://api.ipify.org 2>/dev/null || echo "Unknown")
    echo "🌐 Network:"
    echo "   Domain: $DOMAIN"
    echo "   Public IP: $PUBLIC_IP"
    echo ""
    
    # Container status
    echo "🐳 Containers:"
    echo "   Name            Status    Ports"
    echo "   -----------------------------------"
    docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | tail -n +2 | while read line; do
        echo "   $line"
    done
    echo ""
    
    # Resource usage
    echo "📊 Resources:"
    docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}" | tail -n +2 | while read line; do
        echo "   $line"
    done
    echo ""
    
    # Connection test
    echo "🔌 Quick Connection Test:"
    for i in {1..3}; do
        PORT=$((54040 + i))
        if docker ps --format "{{.Names}}" | grep -q "freelancer$i"; then
            echo -n "   Port $PORT: "
            if timeout 1 nc -z localhost $PORT >/dev/null 2>&1; then
                echo "✓ Open"
            else
                echo "✗ Closed"
            fi
        fi
    done
    echo ""
    
    # Last update
    echo "🔄 Last Updates:"
    if [ -f "/opt/cloudflare-ddns/update.log" ]; then
        tail -1 /opt/cloudflare-ddns/update.log
    fi
    echo ""
    
    echo "Press Ctrl+C to exit. Refreshing in 5 seconds..."
    sleep 5
done
EOF
    
    chmod +x "$PROJECT_DIR/monitor.sh"
    
    print_status "Monitoring system created!"
}

# Function: Create router configuration guide
create_router_guide() {
    print_header "STEP 11: ROUTER CONFIGURATION GUIDE"
    
    cat > "$PROJECT_DIR/ROUTER_SETUP.md" << EOF
# Router Port Forwarding Configuration

## IMPORTANT: You MUST configure your router for external access

## Your Server Information:
- Local IP Address: $SERVER_LOCAL_IP
- Public IP Address: $SERVER_PUBLIC_IP
- Domain: $DOMAIN

## Required Port Forwarding Rules:

Add these rules in your router's admin panel:

### For NoMachine Access:
| External Port | Internal Port | Protocol | Internal IP | Service |
|--------------|---------------|----------|-------------|---------|
EOF

    for i in $(seq 1 $NUMBER_OF_FREELANCERS); do
        PORT=$((54040 + i))
        echo "| $PORT | $PORT | TCP | $SERVER_LOCAL_IP | NoMachine freelancer$i |" >> "$PROJECT_DIR/ROUTER_SETUP.md"
    done
    
    cat >> "$PROJECT_DIR/ROUTER_SETUP.md" << EOF

### For SSH Access (Optional):
| External Port | Internal Port | Protocol | Internal IP | Service |
|--------------|---------------|----------|-------------|---------|
EOF

    for i in $(seq 1 $NUMBER_OF_FREELANCERS); do
        PORT=$((52520 + i))
        echo "| $PORT | $PORT | TCP | $SERVER_LOCAL_IP | SSH freelancer$i |" >> "$PROJECT_DIR/ROUTER_SETUP.md"
    done
    
    cat >> "$PROJECT_DIR/ROUTER_SETUP.md" << EOF

## Steps to Configure:

1. **Access Router Admin:**
   - Open browser to: http://192.168.1.1 (or your router's IP)
   - Login with admin credentials (check router label)

2. **Find Port Forwarding Section:**
   - Usually under: Advanced → NAT Forwarding → Port Forwarding
   - Or: Firewall → Port Forwarding

3. **Add Rules:**
   - For each port listed above, add a new rule
   - Name: "Freelancer [X]"
   - External Port: [Port number]
   - Internal Port: [Same port number]
   - Internal IP: $SERVER_LOCAL_IP
   - Protocol: TCP

4. **Save and Reboot Router:**
   - Save all rules
   - Reboot router if prompted

5. **Test Configuration:**
   - From another network (use phone hotspot), test:
     \`\`\`bash
     telnet $DOMAIN 4001
     \`\`\`
   - Or use: https://www.yougetsignal.com/tools/open-ports/

## Troubleshooting:

1. **Can't access router admin?**
   - Check router IP: \`ip route | grep default\`
   - Try common IPs: 192.168.1.1, 192.168.0.1, 10.0.0.1

2. **Ports still closed after setup?**
   - Check firewall on server: \`sudo ufw status\`
   - Ensure Docker is running: \`sudo systemctl status docker\`
   - Test locally: \`nc -zv localhost 4001\`

3. **Dynamic IP issues?**
   - Set static IP for server in router DHCP settings
   - Reserve IP $SERVER_LOCAL_IP for server's MAC address

## Security Notes:
- Only forward necessary ports
- Consider changing default SSH port
- Enable router firewall if available
- Monitor for unusual connections
EOF
    
    print_status "Router configuration guide created: $PROJECT_DIR/ROUTER_SETUP.md"
}

# Function: Create freelancer guide
create_freelancer_guide() {
    print_header "STEP 12: CREATING FREELANCER GUIDES"
    
    cat > "$PROJECT_DIR/FREELANCER_GUIDE.md" << 'EOF'
# Freelancer Connection Guide

## Quick Start:

1. **Download NoMachine** (free): https://www.nomachine.com/download
2. **Install** and open NoMachine
3. **Click** "New Connection"
4. **Enter Your Connection Details:**
Host: [See table below]
Port: [See table below]
5. **Click** "Connect"
6. **Login with:**
Username: freelancer
Password: freelancer123
7. **Chrome will auto-open** with:
- Tab 1: Worksite (already logged in)
- Tab 2: Activity tracker (timer running)
8. **Work normally**, disconnect when done

## Connection Details:

| Freelancer | Host | Port | Notes |
|------------|------|------|-------|
EOF

 for i in $(seq 1 $NUMBER_OF_FREELANCERS); do
     echo "| freelancer$i | $DOMAIN | $((54040 + i)) | Default password |" >> "$PROJECT_DIR/FREELANCER_GUIDE.md"
 done
 
 cat >> "$PROJECT_DIR/FREELANCER_GUIDE.md" << 'EOF'

## Detailed Instructions:

### For Windows:
1. Download: https://www.nomachine.com/download/download&id=5
2. Run the installer
3. Follow installation wizard
4. Open NoMachine from Start Menu
5. Click "+" to add new connection
6. Enter your host and port from table above
7. Save and connect

### For macOS:
1. Download: https://www.nomachine.com/download/download&id=6
2. Open the .dmg file
3. Drag NoMachine to Applications
4. Open from Applications folder
5. Click "New Connection"
6. Enter connection details

### For Linux:
1. Download: https://www.nomachine.com/download/download&id=7
2. Install with package manager or .deb/.rpm file
3. Open from applications menu
4. Create new connection

## Troubleshooting:

### Connection Issues:
- **"Connection refused"**: Check if port is correct
- **"Host not found"**: Check internet connection
- **Slow performance**: Reduce display quality in NoMachine settings

### Login Issues:
- Username is always: `freelancer`
- Password is always: `freelancer123`
- If login fails, contact administrator

### Chrome Not Opening:
- Wait 1 minute, Chrome auto-starts
- Never close Chrome manually
- If stuck, disconnect and reconnect

## Security Rules:
1. ✅ Work only during assigned hours
2. ✅ Use only the provided Chrome browser
3. ✅ Save work frequently
4. ✅ Logout properly via NoMachine menu
5. ❌ Don't install software or extensions
6. ❌ Don't visit personal websites
7. ❌ Don't share login details

## Support:
- Technical Issues: tech@yourdomain.com
- Work Issues: manager@yourdomain.com
- Emergency: [Phone Number]
- Hours: Mon-Fri, 9AM-6PM EST

## Tips:
- Use wired internet for better performance
- Close other applications when working
- Report issues immediately
- Backup important work locally
EOF
 
 # Create individual connection cards
 for i in $(seq 1 $NUMBER_OF_FREELANCERS); do
     cat > "$PROJECT_DIR/freelancer${i}_connection.txt" << EOF
============================================
    FREELANCER $i - CONNECTION CARD
============================================

CONNECTION DETAILS:
Host: $DOMAIN
Port: $((54040 + i))

LOGIN CREDENTIALS:
Username: freelancer
Password: freelancer123

SOFTWARE REQUIRED:
NoMachine Client (Free)
Download: https://www.nomachine.com

CONNECTION STEPS:
1. Install NoMachine
2. Open NoMachine
3. Click "New Connection"
4. Enter host and port above
5. Click "Connect"
6. Enter username and password

SUPPORT:
Email: support@yourdomain.com
Phone: +1-XXX-XXX-XXXX

============================================
  DO NOT SHARE THIS CARD WITH OTHERS
============================================
EOF
 done
 
 print_status "Freelancer guides created!"
}

# Function: Final verification
final_verification() {
 print_header "STEP 13: FINAL SYSTEM VERIFICATION"
 
 echo "Running verification tests..."
 echo ""
 
 # Test 1: Docker
 print_step "1. Docker Test..."
 if docker ps > /dev/null 2>&1; then
     print_status "Docker: ✓ Running"
 else
     print_error "Docker: ✗ Not running"
 fi
 
 # Test 2: Containers
 print_step "2. Container Test..."
 RUNNING_CONTAINERS=$(docker ps -q | wc -l)
 if [ "$RUNNING_CONTAINERS" -ge "$NUMBER_OF_FREELANCERS" ]; then
     print_status "Containers: ✓ $RUNNING_CONTAINERS running"
 else
     print_warning "Containers: ⚠ Only $RUNNING_CONTAINERS running (expected $NUMBER_OF_FREELANCERS)"
 fi
 
 # Test 3: Ports
 print_step "3. Port Test..."
 for i in $(seq 1 $NUMBER_OF_FREELANCERS); do
     PORT=$((54040 + i))
     if timeout 1 nc -z localhost $PORT >/dev/null 2>&1; then
         print_status "Port $PORT: ✓ Open"
     else
         print_error "Port $PORT: ✗ Closed"
     fi
 done
 
 # Test 4: Cloudflare DDNS
 print_step "4. Cloudflare DDNS Test..."
 if systemctl is-active cloudflare-ddns.timer >/dev/null 2>&1; then
     print_status "DDNS Timer: ✓ Active"
 else
     print_error "DDNS Timer: ✗ Inactive"
 fi
 
 # Test 5: Firewall
 print_step "5. Firewall Test..."
 if ufw status | grep -q "Status: active"; then
     print_status "Firewall: ✓ Active"
 else
     print_error "Firewall: ✗ Inactive"
 fi
 
 echo ""
 print_header "SYSTEM READY FOR DEPLOYMENT"
 
 cat > "$PROJECT_DIR/SYSTEM_SUMMARY.md" << EOF
# System Deployment Complete

## System Information:
- Server IP: $SERVER_PUBLIC_IP
- Domain: $DOMAIN
- Local IP: $SERVER_LOCAL_IP
- Number of Freelancers: $NUMBER_OF_FREELANCERS
- Project Directory: $PROJECT_DIR

## Important Files:
1. Management Script: $PROJECT_DIR/manage.sh
2. Monitoring: $PROJECT_DIR/monitor.sh
3. Router Guide: $PROJECT_DIR/ROUTER_SETUP.md
4. Freelancer Guide: $PROJECT_DIR/FREELANCER_GUIDE.md

## Management Commands:
- Start all: \`cd $PROJECT_DIR && ./manage.sh start\`
- Monitor: \`cd $PROJECT_DIR && ./monitor.sh\`
- Status: \`cd $PROJECT_DIR && ./manage.sh status\`
- Backup: \`cd $PROJECT_DIR && ./manage.sh backup\`
- Configure: \`cd $PROJECT_DIR && ./manage.sh config\`

## Next Steps:
1. ✅ Run: $PROJECT_DIR/ROUTER_SETUP.md
2. ✅ Test external connectivity
3. ✅ Configure freelancer credentials
4. ✅ Distribute connection cards
5. ✅ Monitor system performance

## Test Connection:
From another network, test:
\`\`\`bash
telnet $DOMAIN 4001
\`\`\`

## Support:
For issues, check logs:
\`\`\`bash
cd $PROJECT_DIR && ./manage.sh logs freelancer1
\`\`\`
EOF
 
 print_status "System summary created: $PROJECT_DIR/SYSTEM_SUMMARY.md"
 echo ""
 print_status "🎉 DEPLOYMENT COMPLETE! 🎉"
 echo ""
 print_status "Run this command to start monitoring:"
 echo "  cd $PROJECT_DIR && ./monitor.sh"
}

# Main execution flow
main() {
 print_header "FREELANCER SYSTEM REBUILD"
 echo "This script will completely rebuild the freelancer management system"
 echo "from scratch. This includes removing any existing setup."
 echo ""
 echo "Configuration:"
 echo "  Domain: $DOMAIN"
 echo "  Freelancers: $NUMBER_OF_FREELANCERS"
 echo "  Project Dir: $PROJECT_DIR"
 echo ""
 
 read -p "Continue with rebuild? (y/N): " -n 1 -r
 echo
 if [[ ! $REPLY =~ ^[Yy]$ ]]; then
     print_error "Rebuild cancelled"
     exit 1
 fi
 
 # Get public IP
 get_public_ip
 
 # Execute all steps
 uninstall_existing
 install_dependencies
 setup_firewall
 setup_cloudflare_ddns
 create_project_structure
 create_dockerfile
 create_docker_compose
 create_automation_script
 build_and_start
 create_monitoring
 create_router_guide
 create_freelancer_guide
 final_verification
}

# Run main function
main "$@"