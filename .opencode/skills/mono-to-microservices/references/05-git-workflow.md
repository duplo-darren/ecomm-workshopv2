# Reference: Git Workflow

## Repository Strategy

The migration work lives in a dedicated repository separate from the application code. This
keeps infrastructure history clean and allows the migration to proceed without cluttering
application repos with Terraform and Kubernetes boilerplate.

If you need to make changes *within* an existing application repo (e.g., adding a Dockerfile,
health check endpoint, or environment variable), do that in a branch of the app repo and
reference the PR/commit in the migration repo's git log.

---

## Branching Model

```
main           ← always deployable; represents current prod state
  └── dev      ← integration branch for in-progress work
       ├── feat/phase-1-vpc-eks        ← feature branches per phase/component
       ├── feat/phase-2-user-service
       ├── fix/rds-security-group
       └── docs/architecture-decisions
```

### Branch naming conventions
- `feat/<phase>-<component>` — new infrastructure or service
- `fix/<component>-<issue>` — bug fix or correction
- `docs/<topic>` — documentation only
- `chore/<task>` — maintenance, dependency updates
- `refactor/<component>` — restructuring without functional change

---

## Commit Frequency

**Commit after every meaningful unit of work.** In a migration like this, meaningful units are:

| Situation | Commit |
|-----------|--------|
| Completed one analysis artifact | Yes |
| Added one Terraform module (even if not applied yet) | Yes |
| Applied Terraform successfully | Yes |
| Imported a manually-created resource into Terraform | Yes (with explanation) |
| Added one Kubernetes manifest | Yes |
| Deployed and validated one service in dev | Yes |
| Completed database migration for one service | Yes |
| Completed traffic cutover for one service | Yes |
| Made and immediately reverted a mistake | Yes (revert commit, don't amend) |

Never batch up many changes into one commit. A commit should be explainable in a short message.

---

## Commit Message Format

```
<type>(<scope>): <short imperative description>

[optional body — explain WHY, not WHAT]

[optional footer — refs, breaking changes]
```

### Types
- `feat` — new infrastructure, new service, new capability
- `fix` — correction to something broken or wrong
- `docs` — documentation only
- `chore` — maintenance, formatting, tool configuration
- `refactor` — restructuring without behavior change
- `test` — validation scripts, integration tests
- `revert` — reverting a previous commit

### Scopes
- `terraform` — Terraform code changes
- `k8s` — Kubernetes manifests
- `analysis` — discovery documentation
- `migration` — migration scripts
- `scripts` — helper/utility scripts
- `docs` — architecture docs, ADRs, runbooks
- `ci` — GitHub Actions workflows
- `deps` — provider/module version updates

### Examples

```
feat(terraform): add VPC module with public/private subnets across 3 AZs

Sets up the network foundation for EKS. Uses terraform-aws-modules/vpc v5.x.
NAT Gateway is single in dev, multi-AZ in prod for cost optimization.

Closes #12
```

```
feat(terraform): add EKS cluster with managed node groups

Cluster version 1.31, m5.large Spot nodes in dev.
Includes AWS Load Balancer Controller and External Secrets Operator via Helm.
```

```
fix(terraform): import manually-created sg-0abc123def456789 into state

This security group was created manually via AWS console during initial
RDS testing on 2024-01-15. Now managed by Terraform.

The following command was used to import:
  terraform import aws_security_group.rds_manual sg-0abc123def456789
```

```
feat(k8s): add user-service deployment, service, hpa — validated in dev

IRSA role ARN configured, External Secrets syncing successfully.
Health checks passing, 2/2 replicas running.
```

```
docs(analysis): add bounded context map — 6 candidate services identified

Services: user, order, inventory, billing, notification, api-gateway
Cross-cutting concern identified: billing has shared tables with order service.
Decision to keep billing+order in shared schema for phase 1.
```

---

## Tags and Milestones

Tag significant milestones so you can quickly navigate the history:

```bash
# Tag format: v<major>.<minor>-<milestone>
git tag -a v0.1.0-analysis-complete -m "Phase 1 complete: monolith analysis and service boundaries defined"
git tag -a v0.2.0-infrastructure-dev -m "Phase 3 complete: EKS + RDS + S3 deployed to dev"
git tag -a v0.3.0-services-dev -m "Phase 4 complete: all services containerized and running in dev"
git tag -a v0.4.0-migration-dev -m "Phase 5 complete: data migrated, traffic on microservices in dev"
git tag -a v1.0.0-migration-complete -m "All services migrated to production, monolith decommissioned"
```

```bash
# List all tags
git tag -l

# View tag details
git show v0.2.0-infrastructure-dev

# Push tags to remote
git push origin --tags
```

---

## Linking Infrastructure Changes to Application Changes

When a migration step requires changes to the application repo (e.g., adding a health check):

```bash
# In the application repo
git checkout -b feat/add-health-check-endpoint
# ... make changes ...
git commit -m "feat: add /health/live and /health/ready endpoints for EKS readiness probes"
git push origin feat/add-health-check-endpoint
# Open a PR and get the PR URL
```

```bash
# In the migration repo — reference the app repo change
git commit -m "docs(migration): note user-service requires health check endpoints

Health check endpoints /health/live and /health/ready added in app repo:
  https://github.com/<org>/<app-repo>/pull/456

Deploy this to the service before applying the K8s deployment manifests."
```

---

## .gitignore for the Migration Repo

```gitignore
# Terraform
.terraform/
.terraform.lock.hcl
*.tfplan
tfplan
terraform.tfvars.local
*.auto.tfvars.local
.terraformrc
terraform.rc

# Terraform state (never commit state files)
*.tfstate
*.tfstate.backup
*.tfstate.*.backup

# Sensitive files — never commit
*.pem
*.key
*.p12
.env
.env.*
!.env.example
secrets/
credentials

# Local overrides
*.local

# OS
.DS_Store
Thumbs.db

# Editor
.idea/
.vscode/
*.swp
*.swo

# Python
__pycache__/
*.pyc
.venv/

# Node (if any tooling)
node_modules/

# Build artifacts
dist/
build/
```

---

## Pre-Commit Hooks (optional but recommended)

```bash
# Install pre-commit
pip install pre-commit

# .pre-commit-config.yaml
repos:
- repo: https://github.com/antonbabenko/pre-commit-terraform
  rev: v1.88.0
  hooks:
  - id: terraform_fmt
  - id: terraform_validate
  - id: terraform_docs

- repo: https://github.com/pre-commit/pre-commit-hooks
  rev: v4.5.0
  hooks:
  - id: check-merge-conflict
  - id: detect-private-key
  - id: check-yaml
  - id: end-of-file-fixer
  - id: trailing-whitespace

# Install the hooks
pre-commit install
```

---

## Remote Repository Setup (GitHub)

```bash
# Add remote origin
git remote add origin https://github.com/<org>/<project>-migration.git

# Push initial commit
git push -u origin main

# Set up branch protection for main (do this in GitHub UI or via gh CLI)
gh api repos/<org>/<project>-migration/branches/main/protection \
  --method PUT \
  --field required_status_checks='{"strict":true,"contexts":[]}' \
  --field enforce_admins=false \
  --field required_pull_request_reviews='{"required_approving_review_count":1}' \
  --field restrictions=null
```

---

## Handling Mistakes

If you realize after a commit that something is wrong:

```bash
# For the most recent commit (not yet pushed): amend it
git commit --amend -m "corrected message"

# For already-pushed commits: use revert (never force-push to main)
git revert <commit-sha>
git commit -m "revert: undo <what was wrong> — <why it was wrong>"

# NEVER:
# git push --force origin main    ← destroys history
# git reset --hard HEAD~3         ← losing commits is bad in a migration audit trail
```

The git history of a migration is a forensic artifact. Even mistakes should be visible —
just clearly labeled as such. Future teams will read this history to understand what happened.
