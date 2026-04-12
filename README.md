# homelab-infra

Infrastructure as Code for the homelab project. Provisions an AWS EC2 instance, ECR image registry, IAM role, security group, SSH key pair, and Cloudflare DNS record using Terraform. Configures the server (Docker, AWS CLI, ECR authentication) using Ansible. CI/CD is handled by GitHub Actions hosted runners that build and push Docker images to ECR, then deploy to EC2 via SSH.

---

## what this does

One `./deploy.sh` creates a live server on AWS with a public domain pointing at it, installs everything, and leaves the server ready to receive deployments. Pushing to `main` in the app repo automatically builds a Docker image, pushes it to ECR, and restarts the containers on EC2. Destroy and recreate anytime — the full stack rebuilds from scratch with one command.

---

## stack

| Tool | Purpose |
|---|---|
| Terraform | provisions AWS + Cloudflare resources |
| Ansible | configures the server, installs Docker + AWS CLI, authenticates to ECR |
| AWS EC2 t3.micro | the actual server (eu-west-3, Paris) |
| AWS ECR | private Docker image registry — images built in CI, pulled on EC2 |
| AWS IAM Role | attached to EC2, grants permission to pull from ECR without credentials |
| AWS Security Group | firewall — only ports 22, 80, 443 open |
| Cloudflare | DNS record pointing homelab.skander.cc at EC2 IP |
| GitHub Actions | hosted runners build + push image to ECR, then SSH deploy to EC2 |

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
```

**3. Set GitHub Actions secrets in Skanderba8/homelab:**

| Secret | Value |
|---|---|
| `AWS_ACCESS_KEY_ID` | IAM user access key (needs ECR push permissions) |
| `AWS_SECRET_ACCESS_KEY` | IAM user secret key |
| `ECR_REPOSITORY_URL` | `<account-id>.dkr.ecr.eu-west-3.amazonaws.com/homelab` |
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

Ansible skips starting containers on first provision because ECR is empty. The first GitHub Actions run pushes the image and starts everything.

---

## how deployments work

```
git push to main
  → GitHub Actions (hosted runner, not EC2)
  → checkout code
  → authenticate to ECR
  → docker build + push to ECR (tagged with git SHA + latest)
  → SSH into EC2
  → git pull (syncs docker-compose.yml, nginx.conf)
  → docker compose pull (pulls new image from ECR)
  → docker compose up -d (restarts only changed containers)
```

EC2 never builds anything — it only pulls pre-built images. This keeps the t3.micro free from build load and makes every deployed image permanently addressable by its git SHA.

---

## rebuilding from scratch

```bash
./deploy.sh
```

Then push an empty commit to trigger the first deploy:
```bash
cd ~/homelab && git commit --allow-empty -m "trigger deploy" && git push
```

---

## what terraform provisions

```
AWS eu-west-3
├── aws_ecr_repository         — private Docker image registry (force_delete = true)
├── aws_iam_role                — EC2 assume role for ECR access
├── aws_iam_role_policy_attachment — attaches AmazonEC2ContainerRegistryReadOnly
├── aws_iam_instance_profile    — wraps the role so EC2 can use it
├── aws_key_pair                — uploads ~/.ssh/homelab-ec2.pub to AWS
├── aws_security_group          — allows inbound 22, 80, 443; all outbound
├── aws_instance                — Ubuntu 24.04, t3.micro, with IAM profile attached
└── cloudflare_record           — A record: homelab.skander.cc → EC2 public IP
```

---

## what ansible configures

```
EC2 instance
├── installs Docker (official repo)
├── adds ubuntu user to docker group
├── installs AWS CLI (via pip3 --break-system-packages, Ubuntu 24.04 requirement)
├── clones github.com/Skanderba8/homelab to /home/ubuntu/homelab
├── creates /home/ubuntu/homelab/.env from vars.yml (mode 0600)
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

# check ECR images
aws ecr describe-images --repository-name homelab --region eu-west-3

# terraform
terraform output                # show ECR URL, EC2 IP
terraform state list            # list managed resources
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
Multiple issues stacked on top of each other:
- `appleboy/ssh-action` fingerprint verification kept failing regardless of format — abandoned in favour of plain `ssh` command
- `printf '%s'` strips trailing newline from key file, causing `error in libcrypto` — fixed with `echo | tr -d '\r'`
- `SSH_USER` secret was set to `skander` instead of `ubuntu` — the actual root cause, visible in `/var/log/auth.log` as `Invalid user skander`

**Self-hosted runner no longer needed**
Moved to GitHub-hosted runners for the build+push job. Entire runner installation section removed from Ansible playbook. `GITHUB_PAT` and runner token fetch removed from `deploy.sh`.

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
- Variables passed with `--extra-vars` override everything else.

**ECR + IAM**
- EC2 instances authenticate to ECR via IAM instance profiles — no credentials stored on the server
- IAM has three separate resources: the role (what), the policy attachment (permissions), and the instance profile (the EC2 wrapper)
- `force_delete = true` on ECR is necessary for destroy/rebuild cycles
- `describe-images` returns exit 0 even on empty repos — always check the actual image count

**CI/CD architecture**
- Build once in CI, run anywhere — EC2 should never compile code
- Every image gets two tags: `latest` (what EC2 pulls) and the git SHA (permanent record)
- GitHub-hosted runners are simpler than self-hosted for build jobs — no agent to maintain
- `needs:` in GitHub Actions ensures deploy never runs if build failed

**Debugging SSH**
- `/var/log/auth.log` on the server shows exactly why SSH connections are accepted or rejected
- `ssh-keygen -y -f keyfile` derives the public key from a private key — use to verify they match
- `cat -A` shows line endings — every line in an SSH key must end with `$` (Unix newline)
- When in doubt about what user GitHub is connecting as, check auth.log first

**Ubuntu 24.04 quirks**
- `awscli` removed from apt — use pip3 with `--break-system-packages`
- Python packages require `--break-system-packages` flag for system-wide pip installs

**Secrets management**
- Never hardcode secrets in files that get committed.
- `.env` files hold runtime secrets on the server — created by Ansible, never in git.
- `vars.yml` holds the source of truth for secrets locally — never in git.
- Postgres stores its password in a volume. Changing the env var after first boot has no effect — use `ALTER USER` inside the container.

**AWS**
- Security groups are stateful firewalls — ingress and egress rules defined separately.
- `expose` in docker-compose = internal only. Security group controls what reaches the host.
- AMIs are region-specific.

**Cloudflare**
- Terraform's Cloudflare provider updates DNS automatically when EC2 IP changes.
- `proxied = false` = DNS only. Set to `true` later for DDoS protection and HTTPS termination.
- TTL 60 = DNS records update within 60 seconds.