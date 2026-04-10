# homelab-infra

Infrastructure as Code for the homelab project. Provisions an AWS EC2 instance, security group, SSH key pair, and Cloudflare DNS record using Terraform. Configures the server (Docker, app deployment) using Ansible.

---

## what this does

One `terraform apply` creates a live server on AWS with a public domain pointing at it. One `ansible-playbook` installs everything and starts the app. Destroy and recreate anytime — the full stack rebuilds from scratch with two commands.

---

## stack

| Tool | Purpose |
|---|---|
| Terraform | provisions AWS + Cloudflare resources |
| Ansible | configures the server, installs Docker, deploys app |
| AWS EC2 t3.micro | the actual server (eu-west-3, Paris) |
| AWS Security Group | firewall — only ports 22, 80, 443 open |
| Cloudflare | DNS record pointing homelab.skander.cc at EC2 IP |

---

## structure

```
homelab-infra/
├── main.tf                  # all AWS + Cloudflare resources
├── variables.tf             # variable declarations
├── terraform.tfvars         # your actual values — GITIGNORED, never commit
├── terraform.tfvars.example # template showing required variables
├── .gitignore
└── ansible/
    ├── inventory.ini        # tells Ansible which server to target
    └── playbook.yml         # tasks: install Docker, clone repo, start app
```

---

## prerequisites

- Terraform installed (`terraform --version`)
- Ansible installed (`ansible --version`)
- AWS CLI configured (`aws configure`) with an IAM user that has EC2 permissions
- SSH key pair at `~/.ssh/homelab-ec2` (generate with `ssh-keygen -t ed25519 -f ~/.ssh/homelab-ec2`)
- Cloudflare API token with DNS edit permissions for skander.cc
- Cloudflare Zone ID for skander.cc

---

## setup

**1. Clone and configure:**
```bash
git clone https://github.com/YOUR_USERNAME/homelab-infra
cd homelab-infra
cp terraform.tfvars.example terraform.tfvars
nano terraform.tfvars  # fill in your real values
```

**2. Provision infrastructure:**
```bash
terraform init
terraform plan
terraform apply
```

This creates the EC2 instance, security group, SSH key pair, and Cloudflare DNS record pointing `homelab.skander.cc` at the EC2 IP.

**3. Wait for DNS propagation:**
```bash
nslookup homelab.skander.cc
# should return your EC2 IP
```

If DNS isn't resolving locally, flush the cache:
```bash
sudo systemctl restart systemd-resolved
```

**4. Configure the server:**
```bash
# first time connecting — accept the SSH fingerprint
ssh-keygen -f ~/.ssh/known_hosts -R homelab.skander.cc

ansible-playbook -i ansible/inventory.ini ansible/playbook.yml
```

This installs Docker, clones the homelab repo, and starts the containers.

**5. Verify:**
```bash
curl http://homelab.skander.cc/api/health
```

---

## destroy and rebuild

```bash
# tear everything down
terraform destroy

# rebuild from scratch
terraform apply

# clear old SSH fingerprint (EC2 has a new host key)
ssh-keygen -f ~/.ssh/known_hosts -R homelab.skander.cc

# wait for DNS, then reconfigure
ansible-playbook -i ansible/inventory.ini ansible/playbook.yml
```

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
├── adds Docker's official apt repo (not the outdated Ubuntu default)
├── installs docker-ce, docker-ce-cli, containerd.io, docker-compose-plugin, git
├── adds ubuntu user to docker group
├── clones github.com/YOUR_USERNAME/homelab to /home/ubuntu/homelab
└── runs docker compose up -d --build
```

**Why Ansible and not user_data:**
`user_data` is a bash script that runs once on first boot. It works but has no error handling, no idempotency, and is hard to debug. Ansible is idempotent — run it 10 times, it only changes what needs changing. It also runs on demand, not just on first boot, so you can re-run it after changes.

---

## issues encountered and how they were fixed

**t2.micro not free tier eligible**
Newer AWS accounts use `t3.micro` as the free tier instance. Changed `instance_type` to `t3.micro`.

**Wrong AMI for region**
AMIs are region-specific. Got the correct Ubuntu 24.04 AMI for eu-west-3 by querying AWS directly:
```bash
aws ec2 describe-images \
  --region eu-west-3 \
  --owners 099720109477 \
  --filters "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*" \
  --query "sort_by(Images, &CreationDate)[-1].ImageId" \
  --output text
```

**docker-compose-plugin not available**
Ubuntu's default apt repos don't have the modern Docker Compose plugin. Fixed by adding Docker's official apt repo in the Ansible playbook before installing.

**DNS not resolving locally after apply**
`nslookup homelab.skander.cc 1.1.1.1` worked (Cloudflare's DNS) but local resolver returned NXDOMAIN. Local systemd-resolved had a cached negative response. Fixed with `sudo systemctl restart systemd-resolved`.

**SSH fingerprint mismatch after destroy/apply**
EC2 is a new machine with a new SSH host key. Old fingerprint in `~/.ssh/known_hosts` caused a connection refusal. Fixed with:
```bash
ssh-keygen -f ~/.ssh/known_hosts -R homelab.skander.cc
```

**Terraform repo used wrong Ubuntu codename on Linux Mint**
`lsb_release -cs` returns `zena` on Linux Mint instead of `noble`. Hashicorp has no repo for `zena`. Fixed by hardcoding `noble` in the apt source.

---

## useful commands

```bash
# terraform
terraform init              # download providers
terraform plan              # preview changes
terraform apply             # apply changes
terraform destroy           # destroy everything
terraform output            # show outputs (IP, URL)
terraform state list        # list managed resources
terraform state show cloudflare_record.homelab  # inspect a resource

# ansible
ansible -i ansible/inventory.ini homelab -m ping   # test connection
ansible-playbook -i ansible/inventory.ini ansible/playbook.yml

# ssh into server
ssh -i ~/.ssh/homelab-ec2 ubuntu@homelab.skander.cc

# check containers on server
ssh ubuntu@homelab.skander.cc "docker ps"
```

---

## cost

EC2 t3.micro is free tier for 12 months. After that ~$8-10/month if left running.

Always destroy when not in use:
```bash
terraform destroy
```

---

## things learned

**Terraform**
- Terraform talks to AWS and Cloudflare APIs to create resources. It keeps a state file tracking what exists.
- Every resource has an ID in the state. Destroy removes the real resource and the state entry.
- References between resources (`aws_instance.homelab.public_ip`) are resolved at apply time — no hardcoding IDs.
- `terraform plan` shows exactly what will change before touching anything.
- State file contains sensitive data — never commit it. Store in S3 for team use.

**Ansible**
- Ansible connects via SSH and runs tasks in order. `become: true` runs as root (sudo).
- `state: present` = install if not there, leave alone if already installed (idempotent).
- `become_user: ubuntu` drops back to the ubuntu user for tasks that shouldn't run as root.
- `meta: reset_connection` resets the SSH session to pick up group membership changes (like adding ubuntu to the docker group).

**AWS**
- Security groups are stateful firewalls — you define ingress and egress rules separately.
- `expose` in docker-compose = internal only. Security group rules control what reaches the host.
- AMIs are region-specific. Always query for the correct AMI in your target region.
- t2.micro is legacy free tier. Newer accounts use t3.micro.

**Cloudflare**
- Terraform's Cloudflare provider updates DNS automatically when EC2 IP changes.
- `proxied = false` means DNS only, no Cloudflare proxy. Set to `true` later for DDoS protection and HTTPS termination.
- TTL 60 means DNS records update within 60 seconds — important when IPs change on destroy/apply.