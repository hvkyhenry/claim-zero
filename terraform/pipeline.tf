# =============================================================================
# CLAIM ZERO — Free Tier CI/CD (Lab 4)
# One CodePipeline V1 + CodeBuild SMALL. No Fargate / ALB / NAT / V2.
# Paste this entire file into terraform/pipeline.tf (Lab 4.3).
# =============================================================================

# GitHub owner/repo from terraform.tfvars (Lab 4.3). Example: jane/claim-zero
variable "github_full_repo" {
  description = "GitHub owner/name for the claim-zero repository"
  type        = string
}

# -----------------------------------------------------------------------------
# GitHub connection — Terraform creates it as PENDING.
# You complete the handshake in the console (Lab 4.4) before Source can clone.
# -----------------------------------------------------------------------------
resource "aws_codestarconnections_connection" "github" {
  name          = "claim-zero-github"
  provider_type = "GitHub"
}

# -----------------------------------------------------------------------------
# Artifact bucket — CodePipeline V1 must store zipped source/build output.
# Account ID in the name keeps it globally unique. 1-day expiry. Private.
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "artifacts" {
  bucket        = "claim-zero-artifacts-${local.account_id}"
  force_destroy = true

  tags = {
    Project = local.project
  }
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    id     = "expire-artifacts-1-day"
    status = "Enabled"

    filter {
      prefix = ""
    }

    expiration {
      days = 1
    }
  }
}

# -----------------------------------------------------------------------------
# ECR lifecycle on the existing Lab 2 repo — keep the private repo small.
# Destroy removes this policy only; the ECR repository itself stays.
# -----------------------------------------------------------------------------
resource "aws_ecr_lifecycle_policy" "claim" {
  repository = local.project

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 2 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 2
      }
      action = {
        type = "expire"
      }
    }]
  })
}

# Short retention for CodeBuild logs (workshop only).
resource "aws_cloudwatch_log_group" "codebuild" {
  name              = "/codebuild/${local.project}"
  retention_in_days = 1

  tags = {
    Project = local.project
  }
}

# -----------------------------------------------------------------------------
# IAM — CodeBuild may login to ECR, push claim-zero:latest, write logs, read S3.
# -----------------------------------------------------------------------------
resource "aws_iam_role" "codebuild" {
  name = "${local.project}-codebuild-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "codebuild.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy" "codebuild" {
  name = "${local.project}-codebuild-policy"
  role = aws_iam_role.codebuild.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:PutObject"
        ]
        Resource = "${aws_s3_bucket.artifacts.arn}/*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload"
        ]
        Resource = "arn:aws:ecr:${local.region}:${local.account_id}:repository/${local.project}"
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# CodeBuild — BUILD_GENERAL1_SMALL, privileged (docker build), NOT in a VPC.
# -----------------------------------------------------------------------------
resource "aws_codebuild_project" "claim" {
  name         = "${local.project}-build"
  description  = "CLAIM ZERO Free Tier docker build"
  service_role = aws_iam_role.codebuild.arn

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/amazonlinux-x86_64-standard:5.0"
    type                        = "LINUX_CONTAINER"
    privileged_mode             = true
    image_pull_credentials_type = "CODEBUILD"
  }

  source {
    type = "CODEPIPELINE"
  }

  logs_config {
    cloudwatch_logs {
      group_name = aws_cloudwatch_log_group.codebuild.name
    }
  }

  tags = {
    Project = local.project
  }
}

# -----------------------------------------------------------------------------
# IAM — CodePipeline may use the GitHub connection, start CodeBuild, deploy ECS.
# -----------------------------------------------------------------------------
resource "aws_iam_role" "codepipeline" {
  name = "${local.project}-codepipeline-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "codepipeline.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy" "codepipeline" {
  name = "${local.project}-codepipeline-policy"
  role = aws_iam_role.codepipeline.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:GetBucketVersioning",
          "s3:PutObject"
        ]
        Resource = [
          aws_s3_bucket.artifacts.arn,
          "${aws_s3_bucket.artifacts.arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "codebuild:BatchGetBuilds",
          "codebuild:StartBuild"
        ]
        Resource = aws_codebuild_project.claim.arn
      },
      {
        Effect = "Allow"
        Action = [
          "codestar-connections:UseConnection",
          "codeconnections:UseConnection"
        ]
        Resource = aws_codestarconnections_connection.github.arn
      },
      {
        Effect = "Allow"
        Action = [
          "ecs:DescribeServices",
          "ecs:DescribeTaskDefinition",
          "ecs:DescribeTasks",
          "ecs:ListTasks",
          "ecs:RegisterTaskDefinition",
          "ecs:UpdateService"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = "iam:PassRole"
        Resource = aws_iam_role.ecs_execution.arn
        Condition = {
          StringEqualsIfExists = {
            "iam:PassedToService" = ["ecs-tasks.amazonaws.com"]
          }
        }
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# One V1 pipeline: Source (GitHub) → Build (SMALL) → Deploy (existing ECS).
# pipeline_type = "V1" is required — do not let this become V2.
# -----------------------------------------------------------------------------
resource "aws_codepipeline" "claim" {
  name          = "${local.project}-pipeline"
  pipeline_type = "V1"
  role_arn      = aws_iam_role.codepipeline.arn

  artifact_store {
    location = aws_s3_bucket.artifacts.bucket
    type     = "S3"
  }

  stage {
    name = "Source"

    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeStarSourceConnection"
      version          = "1"
      output_artifacts = ["source_output"]

      configuration = {
        ConnectionArn        = aws_codestarconnections_connection.github.arn
        FullRepositoryId     = var.github_full_repo
        BranchName           = "main"
        DetectChanges        = "true"
        OutputArtifactFormat = "CODE_ZIP"
      }
    }
  }

  stage {
    name = "Build"

    action {
      name             = "Build"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["source_output"]
      output_artifacts = ["build_output"]

      configuration = {
        ProjectName = aws_codebuild_project.claim.name
      }
    }
  }

  stage {
    name = "Deploy"

    action {
      name            = "Deploy"
      category        = "Deploy"
      owner           = "AWS"
      provider        = "ECS"
      version         = "1"
      input_artifacts = ["build_output"]

      configuration = {
        ClusterName = aws_ecs_cluster.claim.name
        ServiceName = aws_ecs_service.app.name
        FileName    = "imagedefinitions.json"
      }
    }
  }

  tags = {
    Project = local.project
  }
}

output "pipeline_name" {
  value = aws_codepipeline.claim.name
}

output "github_connection_arn" {
  value = aws_codestarconnections_connection.github.arn
}