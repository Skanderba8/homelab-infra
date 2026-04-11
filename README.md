# homelab-infra

Infrastructure as Code for the homelab project. Provisions an AWS EC2 instance, security group, SSH key pair, and Cloudflare DNS record using Terraform. Configures the server (Docker, app deployment, GitHub Actions runner) using Ansible.

---

## what this does

One `terraform apply` creates a live server on AWS with a public domain pointing at it. One `ansible-playbook` installs everything, starts the app, and registers a GitHub Actions self-hosted runner on EC2. Destroy and recreate anytime — the full stack rebuilds from scratch with two commands.

---

## stack

| Tool | Purpose |
|---|---|
| Terraform | provisions AWS + Cloudflare resources |
| Ansible | configures the server, installs Docker, deploys app, registers GitHub runner |
| AWS EC2 t3.micro | the actual server (eu-west-3, Paris) |
| AWS Security Group | firewall — only ports 22, 80, 443 open |
| Cloudflare | DNS record pointing homelab.skander.cc at EC2 IP |
| GitHub Actions | self-hosted runner on EC2 for CI/CD |

---

## structure

```
homelab-infra/
├── main.tf                  # all AWS + Cloudflare resources
├── variables.tf             # variable declarations
├── terraform.tfvars         # your actual values — GITIGNORED, never commit
├── terraform.tfvars.example # template showing required variables
├── vars.yml                 # ansible secrets (postgres creds) — GITIGNORED, never commit
├── vars.yml.example         # template showing required variables
├── deploy.sh                # full rebuild script: destroy → apply → ansible
├── .gitignore
└── ansible/
    ├── inventory.ini        # tells Ansible which server to target
    └── playbook.yml         # tasks: install Docker, clone repo, create .env, start app, register runner
```

---

## prerequisites

- Terraform installed (`terraform --version`)
- Ansible installed (`ansible --version`)
- AWS CLI configured (`aws configure`) with an IAM user that has EC2 permissions
- SSH key pair at `~/.ssh/homelab-ec2` (generate with `ssh-keygen -t ed25519 -f ~/.ssh/homelab-ec2`)
- Cloudflare API token with DNS edit permissions for skander.cc
- Cloudflare Zone ID for skander.cc
- GitHub PAT with `repo` scope stored in `~/.bashrc` as `GITHUB_PAT`
- `jq` installed (`sudo apt install jq`)

---

## first time setup

**1. Clone and configure terraform:**
```bash
git clone https://github.com/Skanderba8/homelab-infra
cd homelab-infra
cp terraform.tfvars.example terraform.tfvars
nano terraform.tfvars   # fill in AWS keys, Cloudflare token, zone ID, SSH key path
```

**2. Create vars.yml (never commit this):**
```bash
cp vars.yml.example vars.yml
nano vars.yml   # fill in postgres credentials
```

`vars.yml` format:
```yaml
postgres_user: youruser
postgres_password: yourpassword
postgres_db: calcdb
```

**3. Run the full deploy script:**
```bash
chmod +x deploy.sh
./deploy.sh
```

This does everything in order: terraform destroy (if needed) → apply → clear SSH fingerprint → wait for DNS → wait for SSH → fetch runner token → run Ansible.

---

## rebuilding from scratch (destroy + apply)

Use `deploy.sh` — it handles all the steps automatically:

```bash
./deploy.sh
```

Or manually, step by step:

```bash
# 1. destroy everything
terraform destroy

# 2. provision fresh EC2
terraform apply

# 3. clear old SSH fingerprint (new EC2 = new host key)
ssh-keygen -f ~/.ssh/known_hosts -R homelab.skander.cc

# 4. wait for DNS to propagate, then fetch a fresh runner token
TOKEN=$(curl -s -X POST \
  -H "Authorization: token $GITHUB_PAT" \
  -H "Accept: application/vnd.github+json" \
  https://api.github.com/repos/Skanderba8/homelab/actions/runners/registration-token \
  | jq -r '.token')

# 5. run ansible (creates .env, starts containers, registers runner)
ansible-playbook -i ansible/inventory.ini ansible/playbook.yml \
  --extra-vars "@vars.yml" \
  --extra-vars "github_runner_token=$TOKEN"

# 6. verify
curl http://homelab.skander.cc/api/health
```

---

## re-running ansible on an existing EC2

Use this when you changed `vars.yml` (e.g. updated the postgres password) without destroying the EC2. The runner is already registered so you still need to pass a token (Ansible will skip the registration step if `.credentials` exists, but the variable must still be defined).

```bash
TOKEN=$(curl -s -X POST \
  -H "Authorization: token $GITHUB_PAT" \
  -H "Accept: application/vnd.github+json" \
  https://api.github.com/repos/Skanderba8/homelab/actions/runners/registration-token \
  | jq -r '.token')

ansible-playbook -i ansible/inventory.ini ansible/playbook.yml \
  --extra-vars "@vars.yml" \
  --extra-vars "github_runner_token=$TOKEN"
```

**If you changed the postgres password**, also run this after Ansible finishes to sync the password inside the running database:

```bash
ssh -i ~/.ssh/homelab-ec2 ubuntu@homelab.skander.cc

docker exec -it homelab-db-1 psql -U postgres -c \
  "ALTER USER youruser WITH PASSWORD 'yournewpassword';"

docker compose -f /home/ubuntu/homelab/docker-compose.yml restart backend
```

Why: `POSTGRES_PASSWORD` in `.env` only takes effect on first container creation. After that, postgres stores the password in its volume and ignores the env var. `ALTER USER` is the only way to change it on a running database.

---

## secrets and where they live

| Secret | Where it lives | How it gets to EC2 |
|---|---|---|
| `homelab-ec2` (SSH private key) | `~/.ssh/` on your machine | never leaves your machine |
| `homelab-ec2.pub` (SSH public key) | uploaded to AWS by Terraform | AWS injects it into EC2 at boot |
| postgres credentials | `vars.yml` on your machine | Ansible writes them to `/home/ubuntu/homelab/.env` |
| `GITHUB_PAT` | `~/.bashrc` on your machine | used locally to fetch runner tokens |
| runner token | fetched fresh each time | passed to `config.sh` via Ansible, expires after 1 hour |

Files that must never be committed: `terraform.tfvars`, `vars.yml`, `.env`, `terraform.tfstate`.

---

## what terraform provisions

```
AWS eu-west-3
├── aws_key_pair          — uploads ~/.ssh/homelab-ec2.pub to AWS
├── aws_security_group    — allows inbound 22 (SSH), 80 (HTTP), 443 (HTTPS)
│                           allows all outbound (apt, docker pull, git clone)
├── aws_instance          — Ubuntu 24.04, t3.micro (free tier)
└── cloudflare_record     — A record: homelab.skander.cc → EC2 public IP
```

Security group only exposes what's needed. Port 5432 (postgres) and 8000 (FastAPI) are never open to the internet — they're internal to Docker's network.

---

## what ansible configures

```
EC2 instance
├── installs Docker (official repo, not Ubuntu's outdated version)
├── adds ubuntu user to docker group
├── clones github.com/Skanderba8/homelab to /home/ubuntu/homelab
├── creates /home/ubuntu/homelab/.env from vars.yml (mode 0600, never in git)
├── runs docker compose up -d --build
├── creates /home/ubuntu/actions-runner
├── downloads and extracts GitHub Actions runner binary
├── registers runner with GitHub (skips if .credentials already exists)
├── checks if systemd service file exists before installing (idempotent)
└── installs and starts runner as a systemd service (survives reboots)
```

**Why Ansible and not user_data:**
`user_data` runs once on first boot with no error handling or idempotency. Ansible is idempotent (run it 10 times, it only changes what needs changing), runs on demand, and is easy to debug task by task.

**Why two separate `when` checks for the runner:**
- `when: not runner_credentials.stat.exists` — skips `config.sh` if already registered (`.credentials` file exists)
- `when: not runner_service.stat.exists` — skips `svc.sh install` if service file already exists (prevents "service already exists" error)

Both checks are needed because re-running Ansible on an existing EC2 would otherwise fail trying to re-register and re-install an already-running runner.

---

## github actions runner

The runner is registered as `ec2-runner` with labels `self-hosted,ec2`. It runs as a systemd service under the `ubuntu` user and starts automatically on reboot.

**Runner registration tokens expire after 1 hour.** Always fetch a fresh one before running the playbook.

**If the runner stops responding:**
```bash
ssh -i ~/.ssh/homelab-ec2 ubuntu@homelab.skander.cc

# check status
systemctl status actions.runner.*

# restart
sudo systemctl restart actions.runner.Skanderba8-homelab.ec2-runner.service

# check logs
journalctl -u actions.runner.* -n 50
```

**If jobs are running on the wrong machine:**
Go to GitHub repo → Settings → Actions → Runners and remove any runners that aren't `ec2-runner`.

---

## useful commands

```bash
# full rebuild
./deploy.sh

# terraform
terraform init              # download providers
terraform plan              # preview changes
terraform apply             # apply changes
terraform destroy           # destroy everything
terraform output            # show outputs (EC2 IP, URL)
terraform state list        # list managed resources

# ansible
ansible -i ansible/inventory.ini homelab -m ping   # test SSH connection

# fetch a fresh runner token
TOKEN=$(curl -s -X POST \
  -H "Authorization: token $GITHUB_PAT" \
  -H "Accept: application/vnd.github+json" \
  https://api.github.com/repos/Skanderba8/homelab/actions/runners/registration-token \
  | jq -r '.token')
echo $TOKEN   # verify it printed something

# ssh into server
ssh -i ~/.ssh/homelab-ec2 ubuntu@homelab.skander.cc

# check containers
ssh ubuntu@homelab.skander.cc "docker ps"

# check runner
ssh ubuntu@homelab.skander.cc "systemctl status actions.runner.*"

# check DNS
nslookup homelab.skander.cc
```

---

## cost

EC2 t3.micro is free tier for 12 months. After that ~$8-10/month if left running.

Always destroy when not in use:
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

**github_runner_token undefined error in Ansible**
Token must always be passed via `--extra-vars`. Always fetch a fresh one before running the playbook.

**"service already exists" error when re-running ansible**
`svc.sh install` fails if the systemd service file already exists. Fixed by adding a `stat` check before the install task — skips if service file already present.

**Ansible `when` condition failing with "variable undefined"**
The `stat` task that defines `runner_service` was missing from the playbook. The `when` condition referenced the variable before it was registered. Fixed by adding the `stat` task immediately before the install task.

**Postgres password mismatch after changing vars.yml**
`POSTGRES_PASSWORD` in `.env` only sets the password on first container creation. Changing it afterward has no effect because the password is stored in the postgres volume. Fix: run `ALTER USER` inside the db container, then restart the backend.

**GitHub Actions jobs running on local VM instead of EC2**
Two runners registered with the same label. Fixed by removing the stale local runner from GitHub repo → Settings → Actions → Runners.

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
- `stat:` checks if a file exists. Pattern: stat → register → when: not variable.stat.exists.
- Variables passed with `--extra-vars` override everything else.

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

**GitHub Actions runner**
- Registration tokens expire after 1 hour — always fetch fresh.
- Installed as a systemd service — survives reboots.
- Multiple runners with same label = jobs go to wrong machine. Keep only one registered.
- Runner polls GitHub outbound — no open port needed on EC2.