#!/bin/bash
# deploy.sh — full infrastructure rebuild from scratch
# usage: ./deploy.sh
# run from your infra repo root

set -e  # stop immediately if any command fails

INFRA_DIR="$(cd "$(dirname "$0")" && pwd)"  # directory this script lives in
SSH_KEY="$HOME/.ssh/homelab-ec2"
DOMAIN="homelab.skander.cc"

# ── colours for output ────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # no colour

log()     { echo -e "${GREEN}[+]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
error()   { echo -e "${RED}[x]${NC} $1"; exit 1; }

# ── preflight checks ──────────────────────────────────────────────────────────
log "Checking prerequisites..."

[ -f "$INFRA_DIR/vars.yml" ]            || error "vars.yml not found in $INFRA_DIR"
[ -f "$SSH_KEY" ]                       || error "SSH key not found at $SSH_KEY"
command -v terraform &>/dev/null        || error "terraform not installed"
command -v ansible-playbook &>/dev/null || error "ansible-playbook not installed"
command -v jq &>/dev/null               || error "jq not installed"
[ -n "$GITHUB_PAT" ]                    || error "GITHUB_PAT not set — run: export GITHUB_PAT=your_token"

# ── step 1: terraform destroy ─────────────────────────────────────────────────
log "Destroying existing infrastructure..."
cd "$INFRA_DIR"
terraform destroy -auto-approve

# ── step 2: terraform apply ───────────────────────────────────────────────────
log "Provisioning new infrastructure..."
terraform apply -auto-approve

# grab the new EC2 IP from terraform output
EC2_IP=$(terraform output -raw public_ip 2>/dev/null || echo "")
if [ -z "$EC2_IP" ]; then
  warn "Could not read EC2 IP from terraform output — continuing anyway"
else
  log "EC2 IP: $EC2_IP"
fi

# ── step 3: clear old SSH fingerprint ────────────────────────────────────────
log "Clearing old SSH fingerprint for $DOMAIN..."
ssh-keygen -f "$HOME/.ssh/known_hosts" -R "$DOMAIN" 2>/dev/null || true
# also clear by IP if we got it
[ -n "$EC2_IP" ] && ssh-keygen -f "$HOME/.ssh/known_hosts" -R "$EC2_IP" 2>/dev/null || true

# ── step 4: wait for DNS to propagate ────────────────────────────────────────
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
[ -z "$RESOLVED" ] && error "DNS did not resolve after 4 minutes — check Cloudflare"

# ── step 5: wait for SSH to be ready ─────────────────────────────────────────
log "Waiting for SSH to be ready on $DOMAIN..."
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

# ── step 6: fetch fresh GitHub runner token ───────────────────────────────────
log "Fetching GitHub Actions runner token..."
TOKEN=$(curl -s -X POST \
  -H "Authorization: token $GITHUB_PAT" \
  -H "Accept: application/vnd.github+json" \
  https://api.github.com/repos/Skanderba8/homelab/actions/runners/registration-token \
  | jq -r '.token')

[ -z "$TOKEN" ] || [ "$TOKEN" = "null" ] && error "Failed to fetch runner token — check GITHUB_PAT"
log "Runner token fetched successfully"

# ── step 7: run ansible ───────────────────────────────────────────────────────
log "Running Ansible playbook..."
ansible-playbook -i "$INFRA_DIR/ansible/inventory.ini" \
  "$INFRA_DIR/ansible/playbook.yml" \
  --extra-vars "@$INFRA_DIR/vars.yml" \
  --extra-vars "github_runner_token=$TOKEN"

# ── step 8: verify ────────────────────────────────────────────────────────────
log "Verifying deployment..."
sleep 5  # give containers a moment to fully start

HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://$DOMAIN/api/health" || echo "000")

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Deployment summary"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
[ -n "$EC2_IP" ] && echo "  EC2 IP     : $EC2_IP"
echo "  Domain     : http://$DOMAIN"
echo "  Health     : /api/health → HTTP $HTTP_STATUS"
if [ "$HTTP_STATUS" = "200" ]; then
  echo -e "  Status     : ${GREEN}all good${NC}"
else
  echo -e "  Status     : ${YELLOW}app may still be starting — check docker ps${NC}"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
log "Done. SSH: ssh -i $SSH_KEY ubuntu@$DOMAIN"