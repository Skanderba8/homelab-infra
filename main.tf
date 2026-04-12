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

resource "aws_ecr_repository" "homelab_backend" {
  name                 = "homelab-backend"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name = "homelab-backend-ecr"
  }
}

resource "aws_ecr_repository" "homelab_frontend" {
  name                 = "homelab-frontend"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name = "homelab-frontend-ecr"
  }
}
resource "aws_iam_role" "ec2_ecr_role" {
  name = "homelab-ec2-ecr-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecr_read" {
  role       = aws_iam_role.ec2_ecr_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_instance_profile" "homelab" {
  name = "homelab-instance-profile"
  role = aws_iam_role.ec2_ecr_role.name
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
  iam_instance_profile   = aws_iam_instance_profile.homelab.name  # 👈 add this


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

output "ecr_repository_url" {
  value = aws_ecr_repository.homelab.repository_url
}
