# Reference: Architecture Design

## Service Design Principles

### What makes a good microservice boundary?

A well-bounded microservice:
- Can be **deployed independently** without coordinating with other teams
- **Owns its data** — no other service queries its database directly
- Has a **single, clear responsibility** expressible in one sentence
- Communicates through **explicit contracts** (APIs or events), not shared memory
- Can be **scaled independently** from other services

### Target service size

Prefer services that take 1-2 developers a sprint to understand fully. Services that are too small create excessive network overhead and operational complexity. Services that are too large are just monoliths with better marketing. A team of 5-8 people should be able to own a service end-to-end.

---

## Service Catalog Template

For each service, produce `docs/architecture/services/<name>.md`:

```markdown
# Service: <name>

## Responsibility
<One sentence — what problem does this service solve?>

## Tier
- [ ] API Gateway / BFF
- [ ] Core Domain Service
- [ ] Supporting Service
- [ ] Background Worker
- [ ] Data Pipeline

## Ownership
- Team: <team-name>
- Slack channel: #<channel>
- On-call: <rotation>

## API Contract
### REST Endpoints
| Method | Path | Description |
|--------|------|-------------|
| GET    | /api/v1/resources | List resources |
| POST   | /api/v1/resources | Create resource |
| GET    | /api/v1/resources/{id} | Get resource |
| PUT    | /api/v1/resources/{id} | Update resource |
| DELETE | /api/v1/resources/{id} | Delete resource |

### Events Published
| Event Name | Schema | Trigger |
|------------|--------|---------|
| resource.created | {id, ...} | When resource is created |

### Events Consumed
| Event Name | Source Service | Handler |
|------------|----------------|---------|
| user.verified | user-service | Activates account |

## Data
### Owned Tables
- `resources` — primary entity table
- `resource_tags` — tagging system

### Database
- Instance: `<project>-<service>-db` (or shared in phase 1: `<project>-shared-db`)
- Schema: `<service_name>` (always use a schema even on shared DB)
- Engine: PostgreSQL 16.x on RDS

### S3 Buckets (if applicable)
- `<project>-<service>-assets-<env>` — user-uploaded files

## Dependencies
### Synchronous (must be available)
- user-service: GET /api/v1/users/{id}

### Asynchronous (fire-and-forget)
- Publishes to SQS: `<project>-notification-queue`

## Configuration (Secrets Manager paths)
- `/<project>/<env>/<service>/db-password`
- `/<project>/<env>/<service>/api-key`

## Infrastructure
- EKS Namespace: `<service-name>`
- Min replicas: 2 | Max replicas: 10
- CPU request: 250m | limit: 1000m
- Memory request: 256Mi | limit: 512Mi
- ECR repo: `<account>.dkr.ecr.<region>.amazonaws.com/<project>/<service>`
```

---

## Data Strategy: Shared DB vs. Database per Service

### Phase 1: Shared DB, separate schemas (recommended starting point)

All services share one RDS PostgreSQL instance but each has its own **schema** (PostgreSQL namespace). This gives logical isolation without the operational overhead of many DB instances.

```sql
-- Each service gets its own schema
CREATE SCHEMA user_service;
CREATE SCHEMA order_service;
CREATE SCHEMA billing_service;

-- Grant each app user access only to its schema
CREATE USER user_service_app WITH PASSWORD '...';
GRANT USAGE ON SCHEMA user_service TO user_service_app;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA user_service TO user_service_app;
```

Pros: simple operations, single backup, low cost, easy joins during transition
Cons: services can still do cross-schema queries if not disciplined (enforce via app-level rules)

### Phase 2: Dedicated RDS per service (for high-isolation services)

Migrate to dedicated instances for services that need:
- Independent scaling of storage/compute
- Different PostgreSQL configuration (e.g., pg_trgm extensions, different max_connections)
- Complete data isolation (compliance, multi-tenant)
- Independent maintenance windows

Use Terraform's `rds` module with `count` or `for_each` to manage multiple instances.

### Cross-service data access rules

1. **Never** write to another service's schema/tables directly
2. **Never** JOIN across service schema boundaries in production queries
3. If you need another service's data: call its API, or subscribe to its events
4. For reporting/analytics: use a separate read replica or data warehouse (Redshift/Athena)

---

## Inter-Service Communication Patterns

### Synchronous (REST / gRPC)

Use for:
- User-facing requests where the caller needs an immediate response
- Read queries ("get user profile")
- Validation ("is this user allowed to do X?")

```
Client → Ingress → Service A → Service B (via K8s Service DNS)
                              svc-b.namespace.svc.cluster.local:8080
```

Resilience requirements:
- Implement **retries with exponential backoff** (use a library: resilience4j, tenacity, go-retry)
- Implement **circuit breakers** to prevent cascade failures
- Set **timeouts** on all outbound calls (default: 5s for reads, 30s for writes)
- Health check endpoints: `GET /health/live` and `GET /health/ready`

### Asynchronous (SQS/SNS)

Use for:
- Notifications ("send confirmation email when order is placed")
- Fan-out ("notify 3 systems when user registers")
- Decoupling ("process payment asynchronously")
- Long-running tasks ("generate report", "resize image")

```
Service A → SNS Topic → SQS Queue 1 → Service B
                      → SQS Queue 2 → Service C
```

Pattern: SNS fan-out to multiple SQS queues for event distribution.

Terraform resource pattern:
```hcl
resource "aws_sns_topic" "order_events" {
  name = "${var.project}-order-events-${var.environment}"
}

resource "aws_sqs_queue" "notification_queue" {
  name                      = "${var.project}-notification-queue-${var.environment}"
  visibility_timeout_seconds = 300
  message_retention_seconds  = 86400
  receive_wait_time_seconds  = 20  # long polling

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.notification_dlq.arn
    maxReceiveCount     = 3
  })
}

resource "aws_sqs_queue" "notification_dlq" {
  name = "${var.project}-notification-dlq-${var.environment}"
  message_retention_seconds = 1209600  # 14 days
}

resource "aws_sns_topic_subscription" "notification_sub" {
  topic_arn = aws_sns_topic.order_events.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.notification_queue.arn
}
```

---

## API Gateway Strategy

### AWS ALB + Ingress (recommended for most cases)

The AWS Load Balancer Controller creates ALBs from Kubernetes Ingress resources. This is the
simplest approach that works well for most workloads.

```yaml
# kubernetes/base/ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: main-ingress
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS":443}]'
    alb.ingress.kubernetes.io/certificate-arn: arn:aws:acm:...
    alb.ingress.kubernetes.io/ssl-redirect: "443"
spec:
  rules:
  - host: api.example.com
    http:
      paths:
      - path: /api/v1/users
        pathType: Prefix
        backend:
          service:
            name: user-service
            port:
              number: 8080
      - path: /api/v1/orders
        pathType: Prefix
        backend:
          service:
            name: order-service
            port:
              number: 8080
```

### AWS API Gateway + Lambda (for serverless edge cases)

Consider only if you need rate limiting per API key, request transformation, or have functions
that are truly serverless. Otherwise prefer the ALB approach — it's simpler.

---

## Secrets Management

All secrets MUST go through AWS Secrets Manager. Never use Kubernetes Secrets directly for
application secrets (they're just base64 encoded, not encrypted at rest by default).

### External Secrets Operator (ESO)

Install ESO via Helm:
```bash
helm repo add external-secrets https://charts.external-secrets.io
helm install external-secrets external-secrets/external-secrets \
  -n external-secrets-system \
  --create-namespace \
  --set installCRDs=true
```

Per-service secret sync:
```yaml
# kubernetes/services/<name>/base/externalsecret.yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: <service>-secrets
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: aws-secrets-store
    kind: ClusterSecretStore
  target:
    name: <service>-secrets
    creationPolicy: Owner
  data:
  - secretKey: DB_PASSWORD
    remoteRef:
      key: /<project>/<env>/<service>/db-password
  - secretKey: API_KEY
    remoteRef:
      key: /<project>/<env>/<service>/api-key
```

Terraform creates the secret entries:
```hcl
resource "aws_secretsmanager_secret" "service_db_password" {
  name        = "/${var.project}/${var.environment}/${var.service_name}/db-password"
  description = "RDS password for ${var.service_name}"

  tags = local.common_tags
}

resource "aws_secretsmanager_secret_version" "service_db_password" {
  secret_id     = aws_secretsmanager_secret.service_db_password.id
  secret_string = random_password.db_password.result
}
```

---

## Architecture Decision Record (ADR) Template

```markdown
# ADR-NNN: <Decision Title>

## Status
Proposed | Accepted | Deprecated | Superseded by ADR-NNN

## Context
What is the issue that motivated this decision? What is the current situation?

## Decision
What decision was made? Be specific.

## Consequences
### Positive
- ...

### Negative
- ...

### Risks
- ...

## Alternatives Considered
### Option A: <name>
- Pros: ...
- Cons: ...

### Option B: <name>
- Pros: ...
- Cons: ...

## Date
YYYY-MM-DD
```
