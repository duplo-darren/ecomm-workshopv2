# Reference: Terraform for AWS (EKS + RDS + S3)

## Tool Installation

```bash
# Terraform >= 1.5
curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo apt-key add -
sudo apt-add-repository "deb [arch=amd64] https://apt.releases.hashicorp.com $(lsb_release -cs) main"
sudo apt-get update && sudo apt-get install terraform

# AWS CLI v2
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip && sudo ./aws/install

# kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl && sudo mv kubectl /usr/local/bin/

# Helm 3
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# eksctl (optional but useful)
curl --silent --location "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C /tmp
sudo mv /tmp/eksctl /usr/local/bin
```

---

## Terraform Backend (state)

Place in every `environments/<env>/main.tf`:

```hcl
terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }

  backend "s3" {
    bucket         = "<project>-terraform-state-<account-id>"
    key            = "<env>/terraform.tfstate"
    region         = "<region>"
    dynamodb_table = "<project>-terraform-locks"
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
      Repository  = "<repo-url>"
    }
  }
}
```

---

## Common Variables (shared across modules)

```hcl
# terraform/modules/variables-common.tf (reference, don't create this file directly)
# Include these in each module's variables.tf:

variable "project" {
  description = "Project name, used as prefix for all resources"
  type        = string
}

variable "environment" {
  description = "Deployment environment: dev | staging | prod"
  type        = string
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Environment must be dev, staging, or prod."
  }
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

locals {
  name_prefix = "${var.project}-${var.environment}"

  common_tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}
```

---

## Module: VPC

```hcl
# terraform/modules/vpc/main.tf
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${local.name_prefix}-vpc"
  cidr = var.vpc_cidr  # e.g., "10.0.0.0/16"

  azs             = data.aws_availability_zones.available.names
  private_subnets = var.private_subnet_cidrs  # e.g., ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = var.public_subnet_cidrs   # e.g., ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  enable_nat_gateway   = true
  single_nat_gateway   = var.environment != "prod"  # single NAT in dev/staging
  enable_dns_hostnames = true
  enable_dns_support   = true

  # Required tags for EKS
  public_subnet_tags = {
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${local.name_prefix}" = "owned"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${local.name_prefix}" = "owned"
  }

  tags = local.common_tags
}

data "aws_availability_zones" "available" {
  state = "available"
}
```

---

## Module: ECR

```hcl
# terraform/modules/ecr/main.tf
resource "aws_ecr_repository" "services" {
  for_each = toset(var.service_names)  # ["user-service", "order-service", ...]

  name                 = "${var.project}/${each.value}"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = local.common_tags
}

resource "aws_ecr_lifecycle_policy" "services" {
  for_each   = aws_ecr_repository.services
  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last 30 images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 30
        }
        action = { type = "expire" }
      }
    ]
  })
}

output "repository_urls" {
  value = { for k, v in aws_ecr_repository.services : k => v.repository_url }
}
```

---

## Module: EKS

```hcl
# terraform/modules/eks/main.tf
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = "${local.name_prefix}-cluster"
  cluster_version = "1.31"  # Always use a recent stable version

  vpc_id                   = var.vpc_id
  subnet_ids               = var.private_subnet_ids
  control_plane_subnet_ids = var.private_subnet_ids

  cluster_endpoint_public_access  = true
  cluster_endpoint_private_access = true

  # OIDC provider for IRSA (IAM Roles for Service Accounts)
  enable_irsa = true

  # Enable cluster logging
  cluster_enabled_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  eks_managed_node_groups = {
    general = {
      instance_types = var.node_instance_types  # e.g., ["m5.large", "m5a.large"]
      min_size       = var.node_min_count        # e.g., 2
      max_size       = var.node_max_count        # e.g., 10
      desired_size   = var.node_desired_count    # e.g., 3

      # Use Spot instances in dev to reduce cost
      capacity_type = var.environment == "prod" ? "ON_DEMAND" : "SPOT"

      labels = {
        Environment = var.environment
        NodeGroup   = "general"
      }

      taints = []

      update_config = {
        max_unavailable_percentage = 33
      }
    }
  }

  # Cluster add-ons
  cluster_addons = {
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent    = true
      before_compute = true
    }
    aws-ebs-csi-driver = {
      most_recent = true
    }
  }

  tags = local.common_tags
}

# Update kubeconfig after cluster creation
resource "null_resource" "kubeconfig" {
  depends_on = [module.eks]

  provisioner "local-exec" {
    command = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
  }
}

output "cluster_name"     { value = module.eks.cluster_name }
output "cluster_endpoint" { value = module.eks.cluster_endpoint }
output "cluster_oidc_issuer_url" { value = module.eks.cluster_oidc_issuer_url }
output "oidc_provider_arn" { value = module.eks.oidc_provider_arn }
```

### Install critical cluster components via Helm

```hcl
# terraform/modules/eks/helm.tf

# AWS Load Balancer Controller
resource "helm_release" "aws_load_balancer_controller" {
  depends_on = [module.eks]

  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"
  version    = "1.7.2"

  set {
    name  = "clusterName"
    value = module.eks.cluster_name
  }
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.aws_load_balancer_controller.arn
  }
}

# External Secrets Operator
resource "helm_release" "external_secrets" {
  name       = "external-secrets"
  repository = "https://charts.external-secrets.io"
  chart      = "external-secrets"
  namespace  = "external-secrets-system"
  version    = "0.9.13"

  create_namespace = true

  set {
    name  = "installCRDs"
    value = "true"
  }
}

# Metrics Server (required for HPA)
resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  namespace  = "kube-system"
  version    = "3.12.0"
}
```

---

## Module: RDS PostgreSQL

```hcl
# terraform/modules/rds/main.tf
resource "aws_db_subnet_group" "main" {
  name       = "${local.name_prefix}-db-subnet-group"
  subnet_ids = var.private_subnet_ids

  tags = local.common_tags
}

resource "aws_security_group" "rds" {
  name        = "${local.name_prefix}-rds-sg"
  description = "Security group for RDS PostgreSQL"
  vpc_id      = var.vpc_id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [var.eks_node_security_group_id]
    description     = "PostgreSQL from EKS nodes"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.common_tags
}

resource "random_password" "db_master_password" {
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "aws_secretsmanager_secret" "db_master_password" {
  name        = "/${var.project}/${var.environment}/rds/master-password"
  description = "RDS master password for ${local.name_prefix}"
  tags        = local.common_tags
}

resource "aws_secretsmanager_secret_version" "db_master_password" {
  secret_id     = aws_secretsmanager_secret.db_master_password.id
  secret_string = random_password.db_master_password.result
}

resource "aws_db_instance" "main" {
  identifier = "${local.name_prefix}-postgres"

  engine         = "postgres"
  engine_version = "16.3"  # Always use latest PostgreSQL 16.x
  instance_class = var.db_instance_class  # e.g., "db.t3.medium" (dev), "db.r6g.large" (prod)

  allocated_storage     = var.db_allocated_storage      # e.g., 20 (dev), 100 (prod)
  max_allocated_storage = var.db_max_allocated_storage  # enables autoscaling storage
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = var.db_name
  username = var.db_master_username
  password = random_password.db_master_password.result

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  multi_az               = var.environment == "prod"
  publicly_accessible    = false
  deletion_protection    = var.environment == "prod"
  skip_final_snapshot    = var.environment != "prod"
  final_snapshot_identifier = var.environment == "prod" ? "${local.name_prefix}-final-snapshot" : null

  backup_retention_period = var.environment == "prod" ? 30 : 7
  backup_window           = "03:00-04:00"
  maintenance_window      = "Mon:04:00-Mon:05:00"

  performance_insights_enabled          = true
  performance_insights_retention_period = 7
  monitoring_interval                   = 60
  monitoring_role_arn                   = aws_iam_role.rds_enhanced_monitoring.arn

  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  auto_minor_version_upgrade = true

  tags = local.common_tags
}

output "db_endpoint" { value = aws_db_instance.main.endpoint }
output "db_name"     { value = aws_db_instance.main.db_name }
output "db_port"     { value = aws_db_instance.main.port }
```

### RDS IAM Role for Enhanced Monitoring

```hcl
resource "aws_iam_role" "rds_enhanced_monitoring" {
  name = "${local.name_prefix}-rds-monitoring-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "monitoring.rds.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "rds_enhanced_monitoring" {
  role       = aws_iam_role.rds_enhanced_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}
```

---

## Module: S3

```hcl
# terraform/modules/s3/main.tf
resource "aws_s3_bucket" "service_buckets" {
  for_each = var.buckets  # map of { bucket_key: { name_suffix, purpose } }

  bucket = "${local.name_prefix}-${each.value.name_suffix}"
  tags   = merge(local.common_tags, { Purpose = each.value.purpose })
}

resource "aws_s3_bucket_versioning" "service_buckets" {
  for_each = aws_s3_bucket.service_buckets
  bucket   = each.value.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "service_buckets" {
  for_each = aws_s3_bucket.service_buckets
  bucket   = each.value.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "service_buckets" {
  for_each = aws_s3_bucket.service_buckets
  bucket   = each.value.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "service_buckets" {
  for_each = aws_s3_bucket.service_buckets
  bucket   = each.value.id

  rule {
    id     = "transition-to-ia"
    status = "Enabled"

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = 90
      storage_class = "GLACIER"
    }

    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }
}

output "bucket_names" {
  value = { for k, v in aws_s3_bucket.service_buckets : k => v.bucket }
}

output "bucket_arns" {
  value = { for k, v in aws_s3_bucket.service_buckets : k => v.arn }
}
```

---

## Module: IAM (IRSA — IAM Roles for Service Accounts)

Each Kubernetes service account gets an AWS IAM role via IRSA — no static credentials ever.

```hcl
# terraform/modules/iam/irsa.tf

# Generic IRSA role factory
module "irsa_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name = "${local.name_prefix}-${var.service_name}-irsa"

  oidc_providers = {
    main = {
      provider_arn               = var.oidc_provider_arn
      namespace_service_accounts = ["${var.k8s_namespace}:${var.service_account_name}"]
    }
  }

  role_policy_arns = var.policy_arns

  tags = local.common_tags
}

# Example: S3 access policy for a service
resource "aws_iam_policy" "s3_access" {
  name        = "${local.name_prefix}-${var.service_name}-s3-policy"
  description = "S3 access for ${var.service_name}"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ]
        Resource = [
          "arn:aws:s3:::${var.bucket_name}",
          "arn:aws:s3:::${var.bucket_name}/*"
        ]
      }
    ]
  })
}

# Example: Secrets Manager access policy
resource "aws_iam_policy" "secrets_access" {
  name = "${local.name_prefix}-${var.service_name}-secrets-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:/${var.project}/${var.environment}/${var.service_name}/*"
      }
    ]
  })
}
```

---

## Absorbing Manual Changes Back into Terraform

When you run a manual AWS CLI command or console action that creates/modifies a resource:

### Step 1: Identify the resource ARN/ID
```bash
# Example: you manually created a security group
aws ec2 describe-security-groups --filters "Name=group-name,Values=manually-created-sg" \
  --query 'SecurityGroups[0].GroupId' --output text
# Returns: sg-0abc123def456789
```

### Step 2: Write the Terraform resource
```hcl
resource "aws_security_group" "manually_created" {
  # Describe the resource exactly as it exists
  name        = "manually-created-sg"
  description = "..."
  vpc_id      = module.vpc.vpc_id
  # ... all attributes
}
```

### Step 3: Import into Terraform state
```bash
terraform import aws_security_group.manually_created sg-0abc123def456789
```

### Step 4: Verify no diff
```bash
terraform plan
# Should show: No changes. Your infrastructure matches the configuration.
```

### Step 5: Commit
```bash
git add terraform/
git commit -m "fix(terraform): import manually-created sg sg-0abc123def456789 — created during <reason>"
```

---

## Environment tfvars Template

```hcl
# terraform/environments/dev/terraform.tfvars
project     = "<project>"
environment = "dev"
aws_region  = "us-east-1"

# VPC
vpc_cidr             = "10.0.0.0/16"
private_subnet_cidrs = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
public_subnet_cidrs  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

# EKS
node_instance_types  = ["m5.large"]
node_min_count       = 2
node_max_count       = 5
node_desired_count   = 2

# RDS
db_instance_class        = "db.t3.medium"
db_allocated_storage     = 20
db_max_allocated_storage = 100
db_name                  = "<project>"
db_master_username       = "postgres"

# Services
service_names = ["user-service", "order-service", "notification-service"]
```

---

## Useful Terraform Commands

```bash
# Format all files
terraform fmt -recursive

# Validate configuration
terraform validate

# Plan with detailed output saved
terraform plan -out=tfplan -detailed-exitcode

# Apply saved plan
terraform apply tfplan

# Show current state
terraform show

# List resources in state
terraform state list

# Import existing resource
terraform import <resource_type>.<resource_name> <resource_id>

# Remove resource from state (does NOT destroy it)
terraform state rm <resource_type>.<resource_name>

# Destroy specific resource
terraform destroy -target=<resource_type>.<resource_name>

# Refresh state from real AWS
terraform apply -refresh-only
```
