################################################################################
# main.tf - VPC, Subnet, IGW, Route Table, Security Group, KeyPair, EC2
################################################################################

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# 現在のAWSアカウント情報
data "aws_caller_identity" "current" {}

# 最新の Amazon Linux 2023 AMI
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

################################################################################
# VPC
################################################################################

resource "aws_vpc" "handson" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.project_name}-vpc"
  }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.handson.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = "${var.aws_region}a"

  tags = {
    Name = "${var.project_name}-public-subnet"
  }
}

resource "aws_internet_gateway" "handson" {
  vpc_id = aws_vpc.handson.id

  tags = {
    Name = "${var.project_name}-igw"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.handson.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.handson.id
  }

  tags = {
    Name = "${var.project_name}-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

################################################################################
# Security Group
################################################################################

resource "aws_security_group" "handson" {
  name        = "${var.project_name}-sg"
  description = "Security group for handson code-server"
  vpc_id      = aws_vpc.handson.id

  # HTTPS ステータスページ (管理者用)
  ingress {
    description = "HTTPS status page"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # 管理者用ポート (8000)
  ingress {
    description = "Code Server port for admin"
    from_port   = 8000
    to_port     = 8000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # 参加者用ポート (8000+user_start_number 〜 8000+user_start_number+user_count-1)
  ingress {
    description = "Code Server ports for participants"
    from_port   = 8000 + var.user_start_number
    to_port     = 8000 + var.user_start_number + var.user_count - 1
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # SSH (管理者のみ / admin_cidr が設定されている場合のみ)
  dynamic "ingress" {
    for_each = var.admin_cidr != "" ? [var.admin_cidr] : []
    content {
      description = "SSH from admin"
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = [ingress.value]
    }
  }

  # アウトバウンド全許可
  egress {
    description = "All outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-sg"
  }
}

################################################################################
# SSH Key Pair
################################################################################

resource "tls_private_key" "ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "handson" {
  key_name   = "${var.project_name}-keypair"
  public_key = tls_private_key.ssh.public_key_openssh

  tags = {
    Name = "${var.project_name}-keypair"
  }
}

################################################################################
# EC2 Instance
################################################################################

resource "aws_instance" "handson" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.handson.id]
  key_name               = aws_key_pair.handson.key_name

  # メタデータサービス設定
  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required" # IMDSv2 を強制
  }

  root_block_device {
    volume_size           = var.volume_size
    volume_type           = "gp3"
    delete_on_termination = true

    tags = {
      Name = "${var.project_name}-ebs"
    }
  }

  # user-data は gzip 圧縮して base64 エンコード (16KB制限対策)
  # cloud-init が自動的に gzip を検知・展開する
  user_data_base64 = base64gzip(templatefile("${path.module}/user-data.sh.tpl", {
    users_json_b64 = base64encode(jsonencode([for i in range(var.user_count) : {
      name       = format("user%02d", i + var.user_start_number)
      access_key = aws_iam_access_key.handson[i].id
      secret_key = aws_iam_access_key.handson[i].secret
      password   = random_password.code_server[i].result
    }]))
    user_start_number = var.user_start_number
    admin_json_b64 = base64encode(jsonencode({
      access_key = var.admin_access_key
      secret_key = var.admin_secret_key
      password   = random_password.admin.result
    }))
    aws_account_id = data.aws_caller_identity.current.account_id
    aws_region     = var.aws_region
  }))

  tags = {
    Name = "${var.project_name}-ec2"
  }

  # user-data の変更時にインスタンスを再作成
  lifecycle {
    create_before_destroy = false
  }
}

################################################################################
# Elastic IP (パブリックIPの固定化)
################################################################################

resource "aws_eip" "handson" {
  instance = aws_instance.handson.id
  domain   = "vpc"

  tags = {
    Name = "${var.project_name}-eip"
  }
}
