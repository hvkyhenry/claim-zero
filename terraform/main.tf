# =============================================================================
# CLAIM ZERO — Free Tier ECS on EC2
# Region: us-east-1
# No ALB / Fargate in this edition. Destroy at session end.
# Paste this entire file into terraform/main.tf (Lab 3.1). Do not split it.
# =============================================================================

# Terraform settings: minimum Terraform version + AWS provider pin.
# "~> 5.0" means "any 5.x" — avoids accidental jumps to a new major provider.
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# Every resource below is created in this region (must match ECR: us-east-1).
provider "aws" {
  region = "eu-north-1"
}

# Look up the account currently authenticated via the AWS CLI / credentials.
# Used to build the ECR image URI without hard-coding your account ID.
data "aws_caller_identity" "current" {}

# Reuse the account's default VPC — no custom networking cost for this lab.
data "aws_vpc" "default" {
  default = true
}

# Discover subnets that belong to that default VPC.
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# AWS publishes the recommended ECS-optimised AMI ID in SSM Parameter Store.
# This keeps the lab on a current Amazon Linux 2 ECS AMI without hard-coding.
data "aws_ssm_parameter" "ecs_ami" {
  name = "/aws/service/ecs/optimized-ami/amazon-linux-2/recommended/image_id"
}

locals {
  project    = "claim-zero"
  account_id = data.aws_caller_identity.current.account_id
  region     = "eu-north-1"
  # Must already exist in ECR from Lab 2 of this course.
  # Shape: ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com/claim-zero:latest
  image_uri  = "${local.account_id}.dkr.ecr.${local.region}.amazonaws.com/${local.project}:latest"
  # Pick the first default subnet for the single EC2 host.
  subnet_id  = element(data.aws_subnets.default.ids, 0)
}

# -----------------------------------------------------------------------------
# Networking — allow inbound HTTP (port 80) from the internet to the EC2 host.
# -----------------------------------------------------------------------------
resource "aws_security_group" "ecs" {
  name        = "${local.project}-sg"
  description = "Allow HTTP for CLAIM ZERO Free Tier lab"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Workshop: open HTTP. Tighten in production.
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"          # All outbound (needed for ECR pulls, logs, etc.)
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${local.project}-sg"
    Project = local.project
  }
}

# Logical grouping for ECS services/tasks.
resource "aws_ecs_cluster" "claim" {
  name = "${local.project}-cluster"

  tags = {
    Name    = "${local.project}-cluster"
    Project = local.project
  }
}

# -----------------------------------------------------------------------------
# IAM — EC2 instance role so the ECS agent can register with the cluster.
# -----------------------------------------------------------------------------
resource "aws_iam_role" "ecs_instance" {
  name = "${local.project}-ecs-instance-role"

  # Trust policy: only the EC2 service may assume this role.
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_instance" {
  role       = aws_iam_role.ecs_instance.name
  # AWS managed policy that grants ECS agent permissions on the instance.
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

# Instance profiles are how EC2 instances receive an IAM role.
resource "aws_iam_instance_profile" "ecs" {
  name = "${local.project}-ecs-instance-profile"
  role = aws_iam_role.ecs_instance.name
}

# -----------------------------------------------------------------------------
# IAM — task execution role so ECS can pull from ECR and write CloudWatch logs.
# -----------------------------------------------------------------------------
resource "aws_iam_role" "ecs_execution" {
  name = "${local.project}-ecs-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ecs-tasks.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_execution" {
  role       = aws_iam_role.ecs_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Short retention keeps log cost tiny for a workshop.
resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${local.project}"
  retention_in_days = 3

  tags = {
    Project = local.project
  }
}

# -----------------------------------------------------------------------------
# Compute — one Free Tier–eligible EC2 host joined to the ECS cluster.
# -----------------------------------------------------------------------------
resource "aws_instance" "ecs" {
  ami                         = data.aws_ssm_parameter.ecs_ami.value
  instance_type               = "t3.micro"
  subnet_id                   = local.subnet_id
  vpc_security_group_ids      = [aws_security_group.ecs.id]
  iam_instance_profile        = aws_iam_instance_profile.ecs.name
  # Needed so you can browse http://PUBLIC_IP at the end of Lab 3.
  associate_public_ip_address = true

  # On first boot, tell the ECS agent which cluster to join.
  user_data = base64encode(<<-EOT
    #!/bin/bash
    echo ECS_CLUSTER=${aws_ecs_cluster.claim.name} >> /etc/ecs/ecs.config
  EOT
  )

  tags = {
    Name    = "${local.project}-ecs-instance"
    Project = local.project
  }
}

# -----------------------------------------------------------------------------
# ECS task definition — "what container to run" (image, ports, logs, size).
# -----------------------------------------------------------------------------
resource "aws_ecs_task_definition" "app" {
  family                   = local.project
  requires_compatibilities = ["EC2"]   # Not Fargate in this course
  network_mode             = "bridge"  # Classic Docker bridge on the EC2 host
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  cpu                      = "256"
  memory                   = "512"

  container_definitions = jsonencode([
    {
      name      = local.project
      image     = local.image_uri # ECR URI from Lab 2
      essential = true
      portMappings = [
        {
          containerPort = 80 # nginx inside the container
          hostPort      = 80 # exposed on the EC2 public IP
          protocol      = "tcp"
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.app.name
          "awslogs-region"        = local.region
          "awslogs-stream-prefix" = "ecs"
        }
      }
    }
  ])
}

# -----------------------------------------------------------------------------
# ECS service — keep desired_count tasks running on the cluster.
# -----------------------------------------------------------------------------
resource "aws_ecs_service" "app" {
  name            = "${local.project}-service"
  cluster         = aws_ecs_cluster.claim.id
  task_definition = aws_ecs_task_definition.app.arn
  # Keep exactly one task running (enough for this lab).
  desired_count   = 1
  launch_type     = "EC2"

  # Wait for the EC2 instance resource to exist before creating the service.
  depends_on = [aws_instance.ecs]
}

# -----------------------------------------------------------------------------
# Outputs — values you need to open the live site at the end of Lab 3.
# -----------------------------------------------------------------------------
output "app_url" {
  description = "Browser URL once the ECS task is RUNNING"
  value       = "http://${aws_instance.ecs.public_ip}"
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.claim.name
}

output "ecr_image_uri" {
  value = local.image_uri
}

output "instance_public_ip" {
  value = aws_instance.ecs.public_ip
}