---
name: mono-to-microservices
description: >
  **Monolith-to-Microservices Migration Architect**: Guides the complete analysis, planning, and
  infrastructure buildout for breaking a monolithic application into microservices on AWS.
  Covers EKS (Kubernetes compute), RDS PostgreSQL (database), and S3 (object storage).
  Produces fully reproducible Terraform infrastructure-as-code, Kubernetes manifests, and a
  well-documented git history of every change made.

  Use this skill whenever the user wants to: modernize a monolith, extract microservices,
  migrate to Kubernetes/EKS, decompose a legacy application, re-architect into distributed
  services, containerize components, or "break up" a large application. Also trigger for
  requests like "split this app into services", "move to microservices", "kubernetes migration",
  "containerize our backend", or "decompose our monolith". Any mention of monolith + AWS,
  EKS, microservices, or service extraction should trigger this skill.
---

# Monolith-to-Microservices Migration

This skill guides a full migration from a monolithic application to microservices on AWS using
EKS for compute, RDS PostgreSQL for databases, and S3 for object storage. The migration does
**not** involve rewriting application code — it focuses on decomposition, containerization,
and infrastructure. All infrastructure is expressed as Terraform so the environment can be
fully recreated at any time.

## Core Principles

- **No application rewrites**: Lift-and-shift logic into discrete service containers. Refactor only at boundaries.
- **Infrastructure as Code, always**: Every AWS resource lives in Terraform. If you run a one-off CLI command that creates or modifies a resource, it must be absorbed back into Terraform before moving on.
- **Commit constantly**: After every meaningful step — analysis output, architecture decision, Terraform module, Kubernetes manifest, migration script — commit to git with a clear message. The git log is the audit trail.
- **Reproducibility first**: The end state must be fully recreatable from a `terraform apply` + `kubectl apply` with no manual steps.
- **Least-privilege, always**: Temporary resources created to facilitate migration (bastion hosts, migration IAM roles, peering connections, data-transfer users) MUST be tracked and removed once the phase that required them is complete. Leaving orphaned access is a security risk.
- **Ask before exposing**: Before creating ingress for any service, always confirm with the user whether the service should be exposed at all, and if so — internal (VPC-only) or external (public internet). Never assume a service needs to be reachable from outside the cluster.

---

## Reference Files

Read the relevant reference file(s) before starting each phase:

| File | Read when… |
|------|-----------|
| `references/01-analysis.md` | Beginning discovery and repo analysis |
| `references/02-architecture.md` | Designing service boundaries and data strategy |
| `references/03-terraform-aws.md` | Writing Terraform for EKS, RDS, S3, VPC, IAM |
| `references/04-kubernetes.md` | Writing K8s manifests, Helm charts, service configs |
| `references/05-git-workflow.md` | Git branching, commit patterns, tagging |
| `references/06-migration-runbook.md` | Step-by-step service extraction and cutover |

---

## Phase Overview

```
Phase 0: Setup          → git repo, workspace, tooling verification
Phase 1: Discovery      → analyze all repos, map the monolith
Phase 2: Architecture   → design service decomposition and data strategy
Phase 3: Foundation     → Terraform: VPC, EKS, RDS, S3, IAM, ECR
Phase 4: Extraction     → containerize services, write K8s manifests
Phase 5: Migration      → data migration, traffic cutover, validation
Phase 6: Hardening      → observability, autoscaling, DR, runbooks
```

Each phase ends with a git commit (or series of commits). Never leave uncommitted changes when moving between phases.

---

## Phase Checkpoints (Mandatory)

At the end of every phase, before starting the next one, you **must** pause and present a
checkpoint to the user. This is not optional — migrations are high-stakes operations and the
user needs the opportunity to review, ask questions, correct course, or delay before you
proceed.

The checkpoint has a fixed structure:

```
─────────────────────────────────────────────────────────────
✅  PHASE <N> COMPLETE — <Phase Name>
─────────────────────────────────────────────────────────────

WHAT WAS DONE:
• <concise bullet of each meaningful thing accomplished>
• <include any decisions made, trade-offs chosen, warnings encountered>
• <mention any open items or things flagged for later>

ARTIFACTS PRODUCED:
• <list key files committed: docs, terraform modules, k8s manifests, scripts>
• Git tag / last commit: <commit message>

─────────────────────────────────────────────────────────────
⏭  NEXT — PHASE <N+1>: <Phase Name>
─────────────────────────────────────────────────────────────

WHAT WILL HAPPEN:
• <clear preview of the work about to be done>
• <highlight anything that will create real AWS resources / incur cost>
• <highlight anything irreversible or that requires downtime>

QUESTIONS FOR YOU BEFORE WE PROCEED:
• <any specific decisions the user needs to make for the next phase>
• <anything ambiguous that was deferred and now needs an answer>

─────────────────────────────────────────────────────────────
Ready to proceed to Phase <N+1>? Any questions or changes
before I start? (Reply "yes" or describe any adjustments.)
─────────────────────────────────────────────────────────────
```

Wait for explicit confirmation before starting the next phase. If the user describes
adjustments, apply them, re-commit if anything changed, then re-present the checkpoint.
Never auto-advance. Even if the user seems in a hurry, a one-line "yes, proceed" is
enough — but you must get it.

---

## Phase 0: Setup

Before any analysis, establish the working environment.

### 0.1 Verify tooling

```bash
# Check required tools
for tool in git terraform aws kubectl helm docker jq yq; do
  command -v $tool >/dev/null 2>&1 && echo "✓ $tool" || echo "✗ $tool MISSING"
done

# Check AWS credentials and region
aws sts get-caller-identity
aws configure get region

# Check Terraform version (must be >= 1.5)
terraform version

# Check kubectl
kubectl version --client
```

If tools are missing, install them before proceeding. See the installation commands in `references/03-terraform-aws.md`.

### 0.2 Initialize migration repository

```bash
# Create the infrastructure/migration repository
mkdir -p <project>-migration && cd <project>-migration

git init
git checkout -b main

# Create the canonical directory layout
mkdir -p \
  terraform/{modules/{eks,rds,s3,vpc,iam,ecr},environments/{dev,staging,prod}} \
  kubernetes/{base,overlays/{dev,staging,prod},services} \
  scripts/{analysis,migration,validation} \
  docs/{architecture,decisions,runbooks} \
  .github/workflows

# Initial commit
cat > README.md << 'EOF'
# <Project> Monolith-to-Microservices Migration

This repository contains all infrastructure-as-code, Kubernetes manifests,
migration scripts, and runbooks for decomposing <project> into microservices
on AWS EKS.

## Structure
- `terraform/` — All AWS infrastructure (fully reproducible)
- `kubernetes/` — Kubernetes manifests and Helm charts
- `scripts/` — Migration and validation scripts
- `docs/` — Architecture decisions, runbooks, diagrams
EOF

git add .
git commit -m "chore: initialize migration repository structure"
```

### 0.3 Configure Terraform state backend

```bash
# Create S3 bucket + DynamoDB table for Terraform state (do this ONCE manually, then never again)
aws s3api create-bucket \
  --bucket <project>-terraform-state-$(aws sts get-caller-identity --query Account --output text) \
  --region $(aws configure get region) \
  --create-bucket-configuration LocationConstraint=$(aws configure get region)

aws s3api put-bucket-versioning \
  --bucket <project>-terraform-state-$(aws sts get-caller-identity --query Account --output text) \
  --versioning-configuration Status=Enabled

aws dynamodb create-table \
  --table-name <project>-terraform-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region $(aws configure get region)
```

> These S3/DynamoDB resources for Terraform state are intentionally created manually (bootstrapping). Document them in `docs/decisions/ADR-001-terraform-state.md`.

### ✅ Phase 0 Checkpoint

Present the following to the user before moving to Phase 1:

- Confirm all required tools are installed and their versions
- Confirm AWS credentials are valid and pointing at the correct account and region
- Confirm the migration git repository has been created and the initial commit is in place
- Confirm the Terraform S3 state bucket and DynamoDB lock table exist
- List the repos that will be analyzed in Phase 1 (confirm this is the correct/complete list)
- Ask: "Are there any additional repos, config files, or infrastructure inventories I should
  have access to before starting the analysis?"
- Ask: "Is there anything about the current architecture you'd like me to know upfront
  (e.g., known pain points, previous migration attempts, hard constraints)?"

Wait for confirmation before proceeding.

---

## Phase 1: Discovery

**Read `references/01-analysis.md` before starting this phase.**

### 1.1 Clone and inventory all repositories

```bash
# List all repos to analyze
# For each repo:
git clone <repo-url> analysis/repos/<repo-name>
```

Run the analysis script to get a structural overview:

```bash
python3 scripts/analysis/repo_analysis.py analysis/repos/ > docs/architecture/01-repo-inventory.md
```

### 1.2 Map the monolith

Produce the following artifacts in `docs/architecture/`:
- `02-component-map.md` — list of all identifiable components/modules
- `03-api-inventory.md` — all HTTP endpoints, message queue consumers/producers, cron jobs
- `04-data-model.md` — database schema, table ownership, foreign keys across domains
- `05-dependency-graph.md` — module-to-module dependencies (internal and external)
- `06-infrastructure-inventory.md` — current AWS resources in use

Commit after each artifact:
```bash
git add docs/architecture/
git commit -m "docs(analysis): add <artifact-name>"
```

### 1.3 Identify bounded contexts

Group the components into candidate microservices using Domain-Driven Design bounded contexts. For each candidate service, document:
- Responsibility (one sentence)
- Owned data (which tables it "owns")
- Inbound/outbound API surface
- External dependencies (third-party services, queues, storage)

Save as `docs/architecture/07-bounded-contexts.md`.

```bash
git add docs/
git commit -m "docs(analysis): define bounded contexts and candidate service list"
```

### ✅ Phase 1 Checkpoint

Present the full discovery summary to the user using the Phase Checkpoint format, then ask:

- "Here are the **N candidate services** I've identified. Do these boundaries make sense,
  or do you see components that should be split differently / kept together?"
- List each candidate service with its one-line responsibility and owned tables
- "Are there any **god tables** or **distributed transactions** I've flagged that you want
  to discuss before we design the architecture?"
- "Are there external dependencies (third-party APIs, legacy queues) that aren't visible in
  the codebase that I should know about?"
- "Any compliance or data residency requirements that affect how we partition data?"

The next phase will produce the definitive service list, data strategy, and ADRs —
getting these right is much cheaper than correcting them after Terraform is applied.
Do not proceed until the user has signed off on the candidate service list.

---

## Phase 2: Architecture Design

**Read `references/02-architecture.md` before starting this phase.**

### 2.1 Finalize service list

For each service, create a service definition card:

```markdown
## Service: <name>

**Responsibility**: <one sentence>
**Tier**: frontend | backend | worker | gateway
**Owned tables**: <list>
**Exposes**: REST /api/v1/<resource> | gRPC | events
**Consumes**: <other services or events>
**Estimated replicas (prod)**: <N>
**Database strategy**: own schema | shared DB (phase 1) | own RDS instance (phase 2)
```

### 2.2 Data migration strategy

Decide for each service whether it gets:
- **Shared DB, separate schema** — lowest migration risk, use for phase 1
- **Own RDS instance** — highest isolation, migrate to this incrementally

Document in `docs/architecture/08-data-strategy.md`.

### 2.3 Inter-service communication

Choose patterns:
- **Synchronous**: REST via Kubernetes Service DNS, or AWS API Gateway
- **Asynchronous**: AWS SQS/SNS (prefer this for event-driven workflows)

Document in `docs/architecture/09-communication-patterns.md`.

### 2.4 Architecture Decision Records

For every significant decision, write an ADR:

```bash
docs/decisions/
├── ADR-001-terraform-state.md
├── ADR-002-eks-node-strategy.md
├── ADR-003-database-per-service.md
├── ADR-004-service-mesh.md   (yes/no decision)
└── ADR-005-ingress-strategy.md
```

```bash
git add docs/
git commit -m "docs(architecture): finalize service decomposition and ADRs"
```

### ✅ Phase 2 Checkpoint

Present the architecture summary using the Phase Checkpoint format, including:

- Final service list (name, responsibility, DB strategy, communication pattern for each)
- Data strategy per service (shared schema vs. own RDS instance, and the rationale)
- Inter-service communication map (which services call which, sync vs. async)
- Key ADRs written and the decisions they captured
- Any risks or open questions flagged during architecture design

Then ask:
- "Does this service decomposition reflect how your team thinks about the system?"
- "Are you comfortable with the data strategy — specifically any services that will share a
  DB in phase 1 but will need to be split later?"
- "Phase 3 will start provisioning real AWS resources and **will incur cost**. Are you happy
  to proceed with the target environments: **dev / staging / prod**? Should we start with
  dev only?"
- "What AWS region(s) should we target? Any multi-region or DR requirements?"
- "Do you have an existing VPC / EKS cluster we should reuse, or is this greenfield?"

This is the last checkpoint before real infrastructure is created. Make sure the user is
fully aligned on the architecture before proceeding.

---

## Phase 3: Foundation Infrastructure (Terraform)

**Read `references/03-terraform-aws.md` before starting this phase.**

Build infrastructure in this order — each module is independently testable:

```
VPC → ECR → EKS → RDS → S3 → IAM → Secrets Manager → Ingress
```

### 3.1 Module structure

```
terraform/
├── modules/
│   ├── vpc/          ← networking foundation
│   ├── ecr/          ← container registries
│   ├── eks/          ← EKS cluster + node groups
│   ├── rds/          ← RDS PostgreSQL instances
│   ├── s3/           ← application S3 buckets
│   ├── iam/          ← roles, policies, IRSA
│   └── secrets/      ← Secrets Manager entries
└── environments/
    ├── dev/
    │   ├── main.tf
    │   ├── variables.tf
    │   └── terraform.tfvars
    ├── staging/
    └── prod/
```

### 3.2 Apply sequence

```bash
cd terraform/environments/dev

# Initialize and validate
terraform init
terraform validate
terraform fmt -recursive

# Plan (always plan before apply)
terraform plan -out=tfplan

# Apply in stages — check the plan carefully
terraform apply tfplan

# After successful apply, commit the state-referencing outputs
git add .
git commit -m "feat(terraform): apply <module-name> for <env>"
```

### 3.3 Temporary Migration Resources — Track and Remove

Some phases require AWS resources that are **only needed during migration** — not in the final
production state. These include:

- **Migration IAM roles/users** — cross-account or elevated access to read legacy data
- **Bastion EC2 instances** — temporary SSH access to legacy databases
- **VPC peering connections** — temporary network link between old and new environments
- **Security group rules** — overly permissive rules opened to enable data transfer
- **SSM sessions or temporary credentials** — one-time data export access

Every such resource must be tracked using the temp resources tracker. Register it immediately
when you create it:

```bash
# Register a temporary resource
bash scripts/temp_resources_tracker.sh register \
  "aws_iam_role" \
  "arn:aws:iam::123456789012:role/migration-data-reader" \
  "Allows EKS migration pod to read from legacy RDS during data copy" \
  "phase-5-migration"

# See all active temp resources
bash scripts/temp_resources_tracker.sh list

# Clean up when the phase is done
bash scripts/temp_resources_tracker.sh cleanup phase-5-migration
```

The tracker commits to git automatically, so there's always an audit trail. Running
`cleanup` at the end of each phase is a hard requirement — do not move to the next
phase until `list` shows zero active resources from the completed phase.

At the end of the migration, `cleanup-all` must show no active resources before the
migration can be declared complete.

### 3.4 The "no orphaned resources" rule

If you ever use `aws cli` or the AWS console to create or modify a resource during troubleshooting:

1. Note exactly what you did (resource type, name, config)
2. **Immediately** write or update the Terraform resource that represents it
3. Run `terraform import` to bring it under Terraform management
4. Verify `terraform plan` shows no diff
5. Commit: `git commit -m "fix(terraform): import <resource> into state — was created manually during <reason>"`

This is non-negotiable. Any resource not in Terraform will be lost when the environment is rebuilt.

### ✅ Phase 3 Checkpoint

Present the infrastructure summary using the Phase Checkpoint format, including:

- List of every AWS resource provisioned (VPC, subnets, EKS cluster, RDS instance(s),
  S3 buckets, ECR repos, IAM roles, Secrets Manager entries)
- Confirmation that `terraform plan` shows no outstanding diff
- Confirmation that `kubectl get nodes` shows healthy nodes
- Confirmation that all Helm releases (LBC, ESO, Metrics Server) are healthy
- Any manual steps taken and confirmation they've been imported into Terraform state
- Any temporary resources registered with the tracker (list them)
- Approximate monthly AWS cost estimate for the provisioned resources

Then ask:
- "Are there any infrastructure concerns before we start containerizing services?"
- "For each service, I need to know: should it be exposed **externally** (public internet),
  **internally** (VPC only), or **not at all** (cluster-internal)? I'll ask per-service
  during Phase 4, but if you have a preference to set globally now, let me know."
- "Do you want me to work through all services in Phase 4, or tackle them one at a time
  with a checkpoint after each?"
- "Are there any services you want to prioritize — or any that should definitely be last
  (e.g., auth, payments)?"

---

## Phase 4: Service Extraction

**Read `references/04-kubernetes.md` before starting this phase.**

### 4.0 Determine service exposure (REQUIRED before scaffolding)

Before creating manifests for **each service**, ask the user explicitly:

> "Should **\<service-name\>** be reachable from outside the Kubernetes cluster?
> - **No** — cluster-internal only (other services call it via K8s DNS, no ingress needed)
> - **Internal** — exposed via an internal ALB, reachable within the VPC / private network but not from the public internet
> - **External** — exposed via an internet-facing ALB, reachable from the public internet

The answer drives the scaffold:
- **None**: `ClusterIP` service only, no Ingress resource, NetworkPolicy restricts ingress to namespace traffic only
- **Internal**: `ClusterIP` + Ingress with `alb.ingress.kubernetes.io/scheme: internal`
- **External**: `ClusterIP` + Ingress with `alb.ingress.kubernetes.io/scheme: internet-facing` (also ensure WAF association and rate limiting are discussed)

Use the scaffold script with the `--expose` flag accordingly:
```bash
bash scripts/service_scaffold.sh <service-name> <namespace> <env> --expose none|internal|external
```

### 4.1 Per-service workflow

For each service (work through them in dependency order — leaf services first):

```bash
# Create service directory
mkdir -p kubernetes/services/<service-name>/{base,overlays/{dev,staging,prod}}
```

Produce for each service:
- `Dockerfile` (in the application repo, or inline here if minimal)
- `kubernetes/services/<name>/base/deployment.yaml`
- `kubernetes/services/<name>/base/service.yaml`
- `kubernetes/services/<name>/base/hpa.yaml`
- `kubernetes/services/<name>/base/serviceaccount.yaml` (for IRSA)
- `kubernetes/services/<name>/base/kustomization.yaml`
- Config and secrets via AWS Secrets Manager + External Secrets Operator (not raw K8s secrets)

### 4.2 Build and push container images

```bash
# Authenticate Docker to ECR
aws ecr get-login-password --region <region> | \
  docker login --username AWS --password-stdin \
  $(aws sts get-caller-identity --query Account --output text).dkr.ecr.<region>.amazonaws.com

# Build
docker build -t <service-name>:<tag> ./path/to/service

# Tag and push
docker tag <service-name>:<tag> <ecr-url>/<service-name>:<tag>
docker push <ecr-url>/<service-name>:<tag>
```

### 4.3 Deploy to dev, validate, promote

```bash
# Apply to dev
kubectl apply -k kubernetes/services/<service-name>/overlays/dev

# Validate
kubectl rollout status deployment/<service-name> -n <namespace>
kubectl get pods -n <namespace> -l app=<service-name>

# Check logs
kubectl logs -n <namespace> -l app=<service-name> --tail=100
```

Commit after each service is validated in dev:

```bash
git add kubernetes/services/<service-name>/
git commit -m "feat(k8s): add <service-name> manifests — validated in dev"
```

### ✅ Phase 4 Checkpoint

Present the service extraction summary using the Phase Checkpoint format, including:

- List of every service containerized, with image digest and ECR location
- Confirmation all services are Running and Ready in dev (`kubectl get pods --all-namespaces`)
- Confirmation health checks pass for every service
- Confirmation External Secrets are syncing for every service
- Exposure summary — which services are internal, external, or cluster-only, and why
- Any services that could not be containerized without application changes (flag the
  specific change needed and confirm it was made in the app repo with a PR reference)
- Any temporary resources created during this phase (ECR pull tokens, etc.)

Then ask:
- "All services are running in dev. Before we start migrating data and shifting traffic,
  do you want to do any manual testing against the dev environment?"
- "Phase 5 will begin moving data and shifting production traffic. This is the point of
  highest operational risk. Are you comfortable proceeding, or do you want to promote
  to staging first and validate there?"
- "Do you have a maintenance window preference for the first traffic cutover? Or should
  we use gradual weighted routing without a maintenance window?"
- "Is there a rollback SLA we need to meet — i.e., if something goes wrong, how quickly
  must we be back to the monolith?"
- "Any services that should be migrated first as a 'canary' before we proceed with the rest?"

---

## Phase 5: Migration and Cutover

**Read `references/06-migration-runbook.md` before starting this phase.**

### 5.1 Database migration

For each service being extracted:
1. Create schema in the target RDS instance
2. Run the migration script (see `scripts/migration/`)
3. Validate row counts and data integrity
4. Configure the service to point at the new DB
5. Remove the old cross-schema FK references

```bash
git add scripts/migration/
git commit -m "feat(migration): add DB migration script for <service-name>"
```

### 5.2 Traffic cutover

Use weighted routing at the ingress/ALB level. Never do big-bang cutovers.

```bash
# Start at 5% to new service, 95% to monolith
# Increase in increments: 5 → 20 → 50 → 100
# Roll back immediately if error rate increases
```

Document the cutover plan in `docs/runbooks/cutover-<service-name>.md`.

### ✅ Phase 5 Checkpoint

Present the migration summary using the Phase Checkpoint format, including:

- Per-service status table:

  | Service | DB migrated | Row count validated | Traffic % | Error rate | Rollback tested |
  |---------|-------------|---------------------|-----------|------------|-----------------|
  | user-service | ✓ | ✓ | 100% | 0.01% | ✓ |
  | ... | | | | | |

- Confirmation that all services are at 100% traffic on new infrastructure
- Confirmation the monolith is serving 0% of migrated routes
- List of temporary resources still active (should be zero or near-zero by now)
- Any data integrity issues found and how they were resolved
- Total downtime incurred (should be zero with weighted routing)

Then ask:
- "All services are migrated and serving 100% of traffic. Before we harden the environment,
  are you satisfied with the stability you've seen over the past [N days]?"
- "Should I decommission the monolith's routes from the load balancer now, or do you want
  to keep them as a cold standby for another week?"
- "Phase 6 (Hardening) has no traffic risk but involves cost — Prometheus/Grafana, Karpenter,
  CloudWatch alarms. Should I proceed with the full suite, or are there components you
  already have in place that I should integrate with instead?"
- "Run `bash scripts/temp_resources_tracker.sh list` together — confirm zero active
  temp resources before proceeding."

---

## Phase 6: Hardening

After all services are migrated:

- **Observability**: Prometheus + Grafana via Helm (or AWS Managed Prometheus), Fluent Bit for log shipping to CloudWatch
- **Autoscaling**: HPA for all services, Karpenter for node autoscaling
- **Disaster Recovery**: RDS automated backups verified, S3 versioning/replication enabled, test restore procedure
- **Network policies**: Kubernetes NetworkPolicy to restrict east-west traffic to what's needed
- **Cost tagging**: All AWS resources tagged with `Project`, `Environment`, `Service`, `ManagedBy=terraform`

### ✅ Phase 6 Checkpoint — Migration Complete

Before tagging the migration complete, run this final checklist with the user:

```
FINAL SIGN-OFF CHECKLIST
─────────────────────────────────────────────────────────────
Infrastructure
  [ ] terraform plan shows zero diff in all environments
  [ ] terraform destroy + terraform apply tested successfully in dev
  [ ] All AWS resources tagged (Project, Environment, Service, ManagedBy=terraform)

Security
  [ ] bash scripts/temp_resources_tracker.sh list → zero active temp resources
  [ ] No IAM users with long-lived access keys in use (IRSA everywhere)
  [ ] External Secrets Operator managing all secrets (no raw K8s secrets)
  [ ] Network policies applied to all namespaces

Reliability
  [ ] HPA tested: scale-up and scale-down verified
  [ ] Liveness/readiness probes confirmed on all services
  [ ] PodDisruptionBudgets in place on all services
  [ ] RDS automated backup retention verified (30 days prod)
  [ ] S3 versioning enabled on all buckets
  [ ] DR restore procedure tested (RDS point-in-time restore)

Observability
  [ ] Logs shipping to CloudWatch (Fluent Bit running)
  [ ] CloudWatch alarms set for error rate, CPU, memory, RDS connections
  [ ] kubectl top nodes / kubectl top pods returning data

Git
  [ ] All commits pushed to remote
  [ ] No uncommitted changes in migration repo
  [ ] CHANGELOG or final summary committed
─────────────────────────────────────────────────────────────
```

Ask the user to confirm each item, then ask:
- "Are you ready for me to tag this as complete?"
- "Should the monolith infrastructure be decommissioned now, or kept for a further period?"
- "Is there anything about this migration you'd want documented differently for future reference?"

Only after explicit confirmation from the user:

```bash
git tag -a v1.0.0-migration-complete -m "All services migrated; environment fully reproducible via terraform apply"
git push --tags
```

---

## Commit Message Convention

```
<type>(<scope>): <short description>

Types: feat | fix | docs | chore | refactor | test
Scopes: terraform | k8s | analysis | migration | scripts | docs | git
```

Examples:
- `feat(terraform): add EKS cluster module with managed node groups`
- `fix(terraform): import manually-created security group into state`
- `docs(analysis): add bounded context map for billing domain`
- `feat(k8s): add order-service deployment and HPA`
- `chore(migration): add data validation script for user table migration`

---

## Important Reminders

1. **Every `aws` CLI resource creation → must become Terraform before the next commit**
2. **Every phase ends with committed, passing code**
3. **Never store secrets in git** — use AWS Secrets Manager + External Secrets Operator
4. **Tag every AWS resource** with at minimum `Project`, `Environment`, `ManagedBy=terraform`
5. **Test `terraform destroy` + `terraform apply` in dev** before calling the migration done
6. **Register every temporary resource** with `scripts/temp_resources_tracker.sh register` the moment it's created, and clean it up before moving to the next phase
7. **Always ask about service exposure** before scaffolding any service — never create an ingress or public endpoint without explicit user confirmation on whether it should be internal or external
8. **Verify least-privilege at migration end** — run `bash scripts/temp_resources_tracker.sh list` and confirm it shows zero active resources before tagging the migration complete
