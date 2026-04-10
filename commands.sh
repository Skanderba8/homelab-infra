ssh-keygen -f '/home/skander/.ssh/known_hosts' -R 'homelab.skander.cc'

terraform destroy
terraform apply
ansible-playbook -i ~/infra/ansible/inventory.ini ~/infra/ansible/playbook.yml