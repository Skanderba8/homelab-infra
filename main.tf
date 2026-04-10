terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region = "eu-west-3"
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

resource "aws_key_pair" "homelab" {
  key_name   = "homelab-key"
  public_key = file("~/.ssh/homelab-ec2.pub")
}

resource "aws_security_group" "homelab" {
  name = "homelab-sg"

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "homelab-sg"
  }
}

resource "aws_instance" "homelab" {
  ami                    = "ami-025ddada2a5392251"
  instance_type          = "t3.micro"
  key_name               = aws_key_pair.homelab.key_name
  vpc_security_group_ids = [aws_security_group.homelab.id]

  tags = {
    Name = "homelab"
  }
}

resource "cloudflare_record" "homelab" {
  zone_id = var.cloudflare_zone_id
  name    = "homelab"
  content = aws_instance.homelab.public_ip
  type    = "A"
  ttl     = 60
  proxied = false
}

output "public_ip" {
  value = aws_instance.homelab.public_ip
}

output "url" {
  value = "http://${var.domain}"
}
