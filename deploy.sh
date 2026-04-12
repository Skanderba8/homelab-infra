#!/bin/bash
set -e

INFRA_DIR="$(cd "$(dirname "$0")" && pwd)"
SSH_KEY="$HOME/.ssh/homelab-ec2"
DOMAIN="homelab.skander.cc"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()   { echo -e "${GREEN}[+]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[x]${NC} $1"; exit 1; }

# preflight
[ -f "$INFRA_DIR/vars.yml" ]            || error "vars.yml not found"
[ -f "$SSH_KEY" ]                       || error "SSH key not found at $SSH_KEY"
command -v terraform &>/dev/null        || error "terraform not installed"
command -v ansible-playbook &>/dev/null || error "ansible-playbook not installed"

# terraform
log "Destroying existing infrastructure..."
cd "$INFRA_DIR"
terraform destroy -auto-approve

log "Provisioning new infrastructure..."
terraform apply -auto-approve

EC2_IP=$(terraform output -raw public_ip 2>/dev/null || echo "")
[ -n "$EC2_IP" ] && log "EC2 IP: $EC2_IP"

# clear old SSH fingerprint
ssh-keygen -f "$HOME/.ssh/known_hosts" -R "$DOMAIN" 2>/dev/null || true
[ -n "$EC2_IP" ] && ssh-keygen -f "$HOME/.ssh/known_hosts" -R "$EC2_IP" 2>/dev/null || true

# wait for DNS
log "Waiting for DNS to resolve $DOMAIN..."
for i in $(seq 1 24); do
  RESOLVED=$(nslookup "$DOMAIN" 1.1.1.1 2>/dev/null | awk '/^Address: / { print $2 }' | tail -1)
  if [ -n "$RESOLVED" ]; then
    log "DNS resolved: $DOMAIN → $RESOLVED"
    break
  fi
  warn "DNS not ready yet... (attempt $i/24, waiting 10s)"
  sleep 10
done
[ -z "$RESOLVED" ] && error "DNS did not resolve after 4 minutes"

# wait for SSH
log "Waiting for SSH to be ready..."
for i in $(seq 1 12); do
  if ssh -i "$SSH_KEY" \
       -o StrictHostKeyChecking=no \
       -o ConnectTimeout=5 \
       -o BatchMode=yes \
       ubuntu@"$DOMAIN" "exit" 2>/dev/null; then
    log "SSH is ready"
    break
  fi
  warn "SSH not ready yet... (attempt $i/12, waiting 10s)"
  sleep 10
done

# ansible
log "Running Ansible playbook..."
ansible-playbook -i "$INFRA_DIR/ansible/inventory.ini" \
  "$INFRA_DIR/ansible/playbook.yml" \
  --extra-vars "@$INFRA_DIR/vars.yml"

# verify
log "Verifying deployment..."
sleep 5
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://$DOMAIN/api/health" || echo "000")

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Deployment summary"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
[ -n "$EC2_IP" ] && echo "  EC2 IP  : $EC2_IP"
echo "  Domain  : http://$DOMAIN"
echo "  Health  : HTTP $HTTP_STATUS"
if [ "$HTTP_STATUS" = "200" ]; then
  echo -e "  Status  : ${GREEN}all good${NC}"
else
  echo -e "  Status  : ${YELLOW}app may still be starting${NC}"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "Done. SSH: ssh -i $SSH_KEY ubuntu@$DOMAIN"