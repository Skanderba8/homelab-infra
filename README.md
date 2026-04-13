# homelab-infra

Infrastructure as Code for the homelab project. Provisions an AWS EC2 instance, ECR image registries, IAM role, security group, SSH key pair, and Cloudflare DNS records using Terraform. Configures the server (Docker, AWS CLI, ECR authentication) using Ansible. CI/CD is handled by GitHub Actions hosted runners that build and push Docker images to ECR, then deploy to EC2 via SSH.

---

## what this does

One `./deploy.sh` creates a live server on AWS with a public domain pointing at it, installs everything, and leaves the server ready to receive deployments. Pushing to `main` in the app repo automatically builds only the changed Docker images, pushes them to ECR, and restarts the affected containers on EC2. Destroy and recreate anytime — the full stack rebuilds from scratch with one command including HTTPS certs, monitoring dashboards, and all configuration.

---

## stack

| Tool | Purpose |
|---|---|
| Terraform | provisions AWS + Cloudflare resources |
| Ansible | configures the server, installs Docker + AWS CLI, authenticates to ECR, writes .env |
| AWS EC2 t3.micro | the actual server (eu-west-3, Paris) |
| AWS ECR | private Docker image registries — one for backend, one for frontend |
| AWS IAM Role | attached to EC2, grants permission to pull from ECR without credentials |
| AWS Security Group | firewall — only ports 22, 80, 443 open |
| Cloudflare | DNS records pointing homelab.skander.cc and grafana.skander.cc at EC2 IP |
| Traefik | reverse proxy — TLS termination, automatic Let's Encrypt certs, routes by hostname |
| GitHub Actions | hosted runners — smart CI that only builds/deploys what changed |

---

## structure

```
homelab-infra/
├── main.tf                  # all AWS + Cloudflare resources
├── variables.tf             # variable declarations
├── terraform.tfvars         # your actual values — GITIGNORED, never commit
├── terraform.tfvars.example # template showing required variables
├── vars.yml                 # ansible variables (postgres creds, AWS region/account) — GITIGNORED
├── vars.yml.example         # template showing required variables
├── deploy.sh                # full rebuild script: destroy → apply → ansible
├── .gitignore
└── ansible/
    ├── inventory.ini        # tells Ansible which server to target
    └── playbook.yml         # tasks: install Docker, clone repo, create .env, ECR auth
```

---

## prerequisites

- Terraform installed (`terraform --version`)
- Ansible installed (`ansible --version`)
- AWS CLI configured (`aws configure`) with an IAM user that has EC2 + ECR permissions
- SSH key pair at `~/.ssh/homelab-ec2` (generate with `ssh-keygen -t ed25519 -f ~/.ssh/homelab-ec2`)
- Cloudflare API token with DNS edit permissions for skander.cc
- Cloudflare Zone ID for skander.cc

---

## first time setup

**1. Clone and configure terraform:**
```bash
git clone https://github.com/Skanderba8/homelab-infra
cd homelab-infra
cp terraform.tfvars.example terraform.tfvars
nano terraform.tfvars
```

**2. Create vars.yml (never commit this):**
```bash
cp vars.yml.example vars.yml
nano vars.yml
```

`vars.yml` format:
```yaml
postgres_user: youruser
postgres_password: yourpassword
postgres_db: calcdb
aws_region: eu-west-3
aws_account_id: "your-account-id"
grafana_password: yourpassword
```

**3. Set GitHub Actions secrets in Skanderba8/homelab:**

| Secret | Value |
|---|---|
| `AWS_ACCESS_KEY_ID` | IAM user access key (needs ECR push permissions) |
| `AWS_SECRET_ACCESS_KEY` | IAM user secret key |
| `ECR_REPOSITORY_URL` | `<account-id>.dkr.ecr.eu-west-3.amazonaws.com/homelab-backend` |
| `SSH_HOST` | `homelab.skander.cc` |
| `SSH_USER` | `ubuntu` |
| `SSH_PRIVATE_KEY` | contents of `~/.ssh/homelab-ec2` |

**4. Run the full deploy script:**
```bash
chmod +x deploy.sh
./deploy.sh
```

**5. Push a commit to main to trigger the first deployment:**
```bash
cd ~/homelab
git commit --allow-empty -m "trigger first deploy"
git push origin main
```

Ansible skips starting containers on first provision because ECR is empty. The first GitHub Actions run pushes the images and starts everything.

---

## how deployments work

```
git push to main
  → GitHub Actions: changes job (dorny/paths-filter)
  │
  ├── app files changed (main.py, Dockerfiles, index.html, nginx.conf)?
  │     → build-and-push: docker build + push only changed images to ECR
  │     → deploy: SSH → git pull → docker compose pull <changed> → docker compose up -d
  │
  └── only infra files changed (docker-compose.yml, monitoring config)?
        → deploy-infra: SSH → git pull → docker compose up -d
        (no image pulling — just applies config changes and restarts affected containers)
```

EC2 never builds anything — it only pulls pre-built images. Every deployed image is permanently addressable by its git SHA for rollbacks. Infra-only changes (memory limits, monitoring config, Traefik config) deploy in ~10 seconds.

---

## what terraform provisions

```
AWS eu-west-3
├── aws_ecr_repository (homelab-backend)   — private registry, force_delete = true
├── aws_ecr_repository (homelab-frontend)  — private registry, force_delete = true
├── aws_iam_role                           — EC2 assume role for ECR access
├── aws_iam_role_policy_attachment         — attaches AmazonEC2ContainerRegistryReadOnly
├── aws_iam_instance_profile               — wraps the role so EC2 can use it
├── aws_key_pair                           — uploads ~/.ssh/homelab-ec2.pub to AWS
├── aws_security_group                     — allows inbound 22, 80, 443; all outbound
├── aws_instance                           — Ubuntu 24.04, t3.micro, IAM profile attached
├── cloudflare_record (homelab)            — A record: homelab.skander.cc → EC2 public IP
└── cloudflare_record (grafana)            — A record: grafana.skander.cc → EC2 public IP
```

---

## what ansible configures

```
EC2 instance
├── installs Docker (official repo)
├── adds ubuntu user to docker group
├── installs AWS CLI (via pip3 --break-system-packages, Ubuntu 24.04 requirement)
├── creates 512MB swapfile (prevents OOM kills on t3.micro)
├── clones github.com/Skanderba8/homelab to /home/ubuntu/homelab
├── creates /home/ubuntu/homelab/.env from vars.yml (mode 0600)
│     includes: postgres creds, DATABASE_URL, GRAFANA_PASSWORD
├── authenticates Docker to ECR (aws ecr get-login-password)
├── resets SSH connection to pick up docker group membership
└── starts containers only if ECR has images (skips on first provision)
```

**Why Ansible and not user_data:**
`user_data` runs once on first boot with no error handling or idempotency. Ansible is idempotent (run it 10 times, it only changes what needs changing), runs on demand, and is easy to debug task by task.

---

## secrets and where they live

| Secret | Where it lives | How it gets to EC2 |
|---|---|---|
| `homelab-ec2` SSH private key | `~/.ssh/` on your machine | never leaves your machine |
| `homelab-ec2.pub` SSH public key | uploaded to AWS by Terraform | AWS injects into EC2 at boot |
| postgres credentials | `vars.yml` locally | Ansible writes to `/home/ubuntu/homelab/.env` |
| grafana admin password | `vars.yml` locally | Ansible writes to `/home/ubuntu/homelab/.env` |
| AWS credentials for CI | GitHub Actions secrets | used by hosted runner to push to ECR |
| ECR pull credentials | IAM instance profile on EC2 | auto-rotated by AWS, never stored |

Files that must never be committed: `terraform.tfvars`, `vars.yml`, `.env`, `terraform.tfstate`.

---

## useful commands

```bash
# full rebuild
./deploy.sh

# trigger a deploy without code changes
cd ~/homelab && git commit --allow-empty -m "redeploy" && git push

# ssh into server
ssh -i ~/.ssh/homelab-ec2 ubuntu@homelab.skander.cc

# check running containers
ssh ubuntu@homelab.skander.cc "docker ps"

# check container logs
ssh ubuntu@homelab.skander.cc "docker logs homelab-backend-1"

# check memory usage
ssh ubuntu@homelab.skander.cc "free -h"
ssh ubuntu@homelab.skander.cc "docker stats --no-stream"

# verify memory limits applied
ssh ubuntu@homelab.skander.cc "docker inspect homelab-grafana-1 | grep -i memory"

# check ECR images
aws ecr describe-images --repository-name homelab-backend --region eu-west-3
aws ecr describe-images --repository-name homelab-frontend --region eu-west-3

# terraform
terraform output                # show ECR URLs, EC2 IP
terraform state list            # list managed resources
terraform plan                  # preview changes before applying
```

---

## cost

EC2 t3.micro is free tier for 12 months. After that ~$8-10/month if left running. Always destroy when not in use:
```bash
terraform destroy
```

---

## issues encountered and how they were fixed

**t2.micro not free tier eligible**
Newer AWS accounts use `t3.micro`. Changed `instance_type` to `t3.micro`.

**Wrong AMI for region**
AMIs are region-specific. Queried the correct Ubuntu 24.04 AMI for eu-west-3:
```bash
aws ec2 describe-images \
  --region eu-west-3 \
  --owners 099720109477 \
  --filters "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*" \
  --query "sort_by(Images, &CreationDate)[-1].ImageId" \
  --output text
```

**docker-compose-plugin not available**
Ubuntu's default apt repos don't have the modern Docker Compose plugin. Fixed by adding Docker's official apt repo in the playbook before installing.

**DNS not resolving locally after apply**
`nslookup homelab.skander.cc 1.1.1.1` worked but local resolver returned NXDOMAIN. Fixed with:
```bash
sudo systemctl restart systemd-resolved
```

**SSH fingerprint mismatch after destroy/apply**
New EC2 = new host key. Fixed with:
```bash
ssh-keygen -f ~/.ssh/known_hosts -R homelab.skander.cc
```

**Terraform repo used wrong Ubuntu codename on Linux Mint**
`lsb_release -cs` returns `zena` on Linux Mint. Fixed by hardcoding `noble` in the apt source.

**Postgres password mismatch after changing vars.yml**
`POSTGRES_PASSWORD` in `.env` only sets the password on first container creation. Changing it afterward has no effect because the password is stored in the postgres volume. Fix: run `ALTER USER` inside the db container, then restart the backend.

**ECR repository not empty on terraform destroy**
`terraform destroy` fails if ECR has images. Fixed by adding `force_delete = true` to the ECR resource. Also required running `terraform apply` first to update state before destroy would work.

**`awscli` not available in apt on Ubuntu 24.04**
Ubuntu 24.04 dropped `awscli` from apt. Fixed by installing via pip3 with `--break-system-packages` flag (required because Ubuntu 24.04 uses an externally managed Python environment).

**ECR image not found on first provision**
Ansible tried to `docker compose pull` before any image existed in ECR. Fixed by adding a task that counts images in ECR and skips container startup if the count is zero. GitHub Actions handles the first real deploy after pushing a commit.

**`aws ecr describe-images` returns exit 0 with empty list**
The ECR check used exit code to detect empty registry, but `describe-images` succeeds even with no images, returning `{"imageDetails": []}`. Fixed by querying `length(imageDetails)` directly and checking if count is greater than 0.

**SSH authentication failing from GitHub Actions**
Multiple issues stacked: `appleboy/ssh-action` fingerprint verification kept failing — abandoned in favour of plain `ssh` command. `printf '%s'` strips trailing newline causing `error in libcrypto` — fixed with `echo | tr -d '\r'`. `SSH_USER` secret was set to `skander` instead of `ubuntu` — the actual root cause, visible in `/var/log/auth.log`.

**Self-hosted runner no longer needed**
Moved to GitHub-hosted runners for the build+push job. Entire runner installation section removed from Ansible playbook.

**Traefik v3.0 incompatible with EC2 Docker daemon**
Traefik v3.0 requires Docker API 1.40+. The EC2 instance ran an older Docker daemon exposing API 1.24. Traefik couldn't discover containers, never triggered ACME, and served its default self-signed cert. Fixed by pinning to `traefik:v2.11`.

**High memory pressure on t3.micro**
911MB total RAM with 805MB used and no swap — one OOM event would kill containers. Fixed by adding `mem_limit` to every container in `docker-compose.yml` and creating a 512MB swapfile via Ansible. Total container ceiling is 800MB leaving headroom for the OS.

**Deploys taking 5 minutes**
`docker compose pull` pulled all 9 images on every push including infrastructure images that never change on an app commit. Fixed with `dorny/paths-filter` in GitHub Actions to detect which files changed, building and pulling only affected images. Infra-only pushes skip image operations entirely.

---

## things learned

**Terraform**
- Talks to AWS and Cloudflare APIs to create resources. Keeps a state file tracking what exists.
- `terraform plan` shows exactly what will change before touching anything.
- References between resources (`aws_instance.homelab.public_ip`) are resolved at apply time.
- State file contains sensitive data — never commit it. Store in S3 for team use.

**Ansible**
- Connects via SSH and runs tasks in order. `become: true` runs as root.
- Idempotent — run it 10 times, it only changes what needs changing.
- `become_user: ubuntu` drops from root to ubuntu for specific tasks.
- `meta: reset_connection` resets SSH session to pick up group membership changes.
- `register:` stores a task result in a variable. `when:` uses that variable to conditionally skip tasks.

**Traefik**
- Container-native reverse proxy — discovers services via Docker socket and labels.
- Handles TLS termination and Let's Encrypt cert lifecycle automatically.
- Requires Docker API 1.40+. Check daemon version before choosing Traefik version.
- Falls back to self-signed cert if ACME fails — always verify with `docker logs homelab-traefik-1`.

**ECR + IAM**
- EC2 instances authenticate to ECR via IAM instance profiles — no credentials stored on the server.
- IAM has three separate resources: the role (what), the policy attachment (permissions), and the instance profile (the EC2 wrapper).
- `force_delete = true` on ECR is necessary for destroy/rebuild cycles.
- `describe-images` returns exit 0 even on empty repos — always check the actual image count.

**CI/CD architecture**
- Build once in CI, run anywhere — EC2 should never compile code.
- Every image gets two tags: `latest` (what EC2 pulls) and the git SHA (permanent record).
- `dorny/paths-filter` detects changed files — avoids unnecessary builds and image pulls.
- Separate jobs for app deploys vs infra-only deploys keeps the pipeline fast and clear.
- `needs:` in GitHub Actions ensures deploy never runs if build failed.

**Resource management**
- A t3.micro has 1GB RAM. Without limits, the monitoring stack alone can starve the app.
- `mem_limit` in Docker Compose is a hard cap — container gets OOM-killed if it exceeds it, not the whole host.
- Swap is a safety net, not a performance strategy — it prevents hard crashes but is slow.

**Debugging SSH**
- `/var/log/auth.log` on the server shows exactly why SSH connections are accepted or rejected.
- `ssh-keygen -y -f keyfile` derives the public key from a private key — use to verify they match.
- `cat -A` shows line endings — every line in an SSH key must end with `$` (Unix newline).

**Ubuntu 24.04 quirks**
- `awscli` removed from apt — use pip3 with `--break-system-packages`.
- Python packages require `--break-system-packages` flag for system-wide pip installs.

**Secrets management**
- Never hardcode secrets in files that get committed.
- `.env` files hold runtime secrets on the server — created by Ansible, never in git.
- `vars.yml` holds the source of truth for secrets locally — never in git.
- Postgres stores its password in a volume. Changing the env var after first boot has no effect.

**AWS**
- Security groups are stateful firewalls — ingress and egress rules defined separately.
- `expose` in docker-compose = internal only. Security group controls what reaches the host.
- AMIs are region-specific.

**Cloudflare**
- Terraform's Cloudflare provider updates DNS automatically when EC2 IP changes.
- `proxied = false` = DNS only. Set to `true` later for DDoS protection and HTTPS termination.
- TTL 60 = DNS records update within 60 seconds.

---

## what's next

- **Secrets management** — move secrets from `vars.yml`/`.env` into AWS Secrets Manager. EC2 fetches them at runtime instead of Ansible writing them at deploy time.
- **Alerting** — Grafana alerts to email or Slack when a container is down or memory exceeds 80%.
- **Uptime monitoring** — HTTP health check hitting `/api/health` every minute with alerting on failure.
- **Multi-environment** — `staging` branch + separate Terraform workspace for testing infra changes before prod.
- **Terraform remote state** — move `terraform.tfstate` to S3 so it's not sitting on a local machine.