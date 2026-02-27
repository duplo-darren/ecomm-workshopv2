# Reference: Migration Runbook

## Pre-Migration Validation Checklist

Before starting any database migration or traffic cutover, verify:

```bash
# Checklist script
cat scripts/validation/pre-migration-checklist.sh
```

- [ ] All Terraform applied successfully (`terraform plan` shows no changes)
- [ ] All K8s pods are Running and Ready (`kubectl get pods --all-namespaces | grep -v Running`)
- [ ] Health checks passing for all new services
- [ ] Database connectivity verified from each service pod
- [ ] Secrets synced from Secrets Manager (`kubectl get externalsecrets --all-namespaces`)
- [ ] S3 bucket access verified for services that need it
- [ ] Rollback procedure documented and tested in dev
- [ ] Monitoring/alerting configured (CloudWatch alarms or Prometheus alerts)
- [ ] On-call rotation alerted about upcoming migration window
- [ ] Change management ticket created (if required by your org)

---

## Database Migration Patterns

### Pattern 1: Schema Copy (same RDS instance, new schema)

When migrating from the monolith's single schema to per-service schemas on the same instance:

```sql
-- Step 1: Create new schema owned by service's DB user
CREATE SCHEMA IF NOT EXISTS order_service;
CREATE USER order_service_app WITH PASSWORD '<password>';
GRANT USAGE ON SCHEMA order_service TO order_service_app;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA order_service TO order_service_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA order_service GRANT ALL ON TABLES TO order_service_app;

-- Step 2: Copy tables with data
CREATE TABLE order_service.orders AS SELECT * FROM public.orders;
CREATE TABLE order_service.order_items AS SELECT * FROM public.order_items;

-- Step 3: Recreate constraints, indexes, sequences
-- (export these from the source schema first)
\d+ public.orders  -- to see DDL in psql

-- Step 4: Validate row counts
SELECT
  (SELECT COUNT(*) FROM public.orders) AS source_count,
  (SELECT COUNT(*) FROM order_service.orders) AS dest_count;

-- Step 5: Reset sequences
SELECT setval('order_service.orders_id_seq',
  (SELECT MAX(id) FROM order_service.orders));
```

### Pattern 2: New RDS Instance Migration (pgdump/pgrestore)

When a service gets its own dedicated RDS instance:

```bash
# Step 1: Export specific tables from the source database
pg_dump \
  -h <source-rds-endpoint> \
  -U postgres \
  -d <dbname> \
  --schema=public \
  -t public.orders \
  -t public.order_items \
  -t public.order_status_history \
  --no-owner \
  --no-acl \
  -Fc \
  -f /tmp/order_service_dump.dump

# Step 2: Create schema on target
psql -h <target-rds-endpoint> -U postgres -d <dbname> \
  -c "CREATE SCHEMA IF NOT EXISTS order_service;"

# Step 3: Restore to target (into target schema)
pg_restore \
  -h <target-rds-endpoint> \
  -U postgres \
  -d <dbname> \
  --schema=order_service \
  --no-owner \
  --no-acl \
  /tmp/order_service_dump.dump

# Step 4: Validate
psql -h <target-rds-endpoint> -U postgres -d <dbname> -c "
SELECT schemaname, tablename, n_live_tup
FROM pg_stat_user_tables
WHERE schemaname = 'order_service'
ORDER BY tablename;
"
```

### Pattern 3: Dual-Write with Sync (zero-downtime)

For high-traffic tables where you cannot afford downtime:

```
Phase A (days-weeks):
  Monolith writes to: old table (primary) + new schema (secondary)
  New service reads from: new schema

Phase B (verify sync is good):
  Run row-count and checksum comparisons hourly
  Monitor replication lag

Phase C (cutover):
  New service becomes primary writer
  Monolith reads from new service API (not DB directly)
  Old table becomes read-only

Phase D (cleanup):
  Remove dual-write code from monolith
  Drop old table (only after N weeks of verified stability)
```

This pattern requires application-level changes, but they're additive changes, not rewrites.

---

## Traffic Cutover Strategy

### Weighted Routing with ALB

The AWS Application Load Balancer supports weighted target groups. Use this to gradually
shift traffic from the monolith to a new service.

**Terraform for weighted routing:**
```hcl
resource "aws_lb_listener_rule" "order_service_weighted" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 100

  action {
    type = "forward"
    forward {
      target_group {
        arn    = aws_lb_target_group.monolith.arn
        weight = var.monolith_weight  # e.g., 90 → 50 → 0
      }
      target_group {
        arn    = aws_lb_target_group.order_service.arn
        weight = var.order_service_weight  # e.g., 10 → 50 → 100
      }
      stickiness {
        enabled  = false
        duration = 1
      }
    }
  }

  condition {
    path_pattern {
      values = ["/api/v1/orders*"]
    }
  }
}
```

**Migration script for weight progression:**
```bash
#!/bin/bash
# scripts/migration/shift-traffic.sh

SERVICE=$1
WEIGHT=$2  # percentage to send to new service (0-100)
ENV=$3

echo "Shifting $WEIGHT% traffic to $SERVICE in $ENV"

cd terraform/environments/$ENV

# Update the weight variable
sed -i "s/^order_service_weight = .*/order_service_weight = $WEIGHT/" terraform.tfvars
sed -i "s/^monolith_weight = .*/monolith_weight = $((100 - $WEIGHT))/" terraform.tfvars

# Apply the change
terraform plan -target=aws_lb_listener_rule.${SERVICE}_weighted -out=tfplan
echo "Review the plan above. Continue? (y/N)"
read -r confirm
if [ "$confirm" == "y" ]; then
  terraform apply tfplan
  echo "Traffic shifted. Monitor error rates for 10 minutes before proceeding."
  git add terraform/environments/$ENV/terraform.tfvars
  git commit -m "feat(migration): shift $WEIGHT% traffic to $SERVICE in $ENV"
else
  echo "Aborted."
  rm -f tfplan
fi
```

### Cutover Sequence

```
Day 1: 0% new service (validate in dev, not in prod)
Day 2: 5% to new service — monitor for 24h
Day 3: 20% — monitor for 24h
Day 4: 50% — monitor for 24h
Day 5: 100% — monitor for 48h
Day 7: Remove monolith route (keep for 2 more weeks)
Day 21: Decommission monolith endpoint
```

---

## Validation Scripts

### Service Health Validation

```bash
#!/bin/bash
# scripts/validation/validate-service.sh

SERVICE=$1
NAMESPACE=${2:-$SERVICE}
ENV=${3:-dev}

echo "=== Validating $SERVICE in $NAMESPACE ($ENV) ==="

# 1. Pod status
echo "\n[Pods]"
kubectl get pods -n $NAMESPACE -l app=$SERVICE

READY=$(kubectl get pods -n $NAMESPACE -l app=$SERVICE \
  -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' | \
  tr ' ' '\n' | grep -c "True")
TOTAL=$(kubectl get pods -n $NAMESPACE -l app=$SERVICE --no-headers | wc -l)

if [ "$READY" -eq "$TOTAL" ] && [ "$TOTAL" -gt 0 ]; then
  echo "✓ $READY/$TOTAL pods ready"
else
  echo "✗ Only $READY/$TOTAL pods ready"
  exit 1
fi

# 2. Health check via port-forward
echo "\n[Health Check]"
kubectl port-forward -n $NAMESPACE svc/$SERVICE 18080:80 &
PF_PID=$!
sleep 2

HEALTH=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:18080/health/ready)
kill $PF_PID 2>/dev/null

if [ "$HEALTH" == "200" ]; then
  echo "✓ /health/ready returned 200"
else
  echo "✗ /health/ready returned $HEALTH"
  exit 1
fi

# 3. External Secrets synced
echo "\n[External Secrets]"
SECRET_STATUS=$(kubectl get externalsecret -n $NAMESPACE ${SERVICE}-secrets \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)

if [ "$SECRET_STATUS" == "True" ]; then
  echo "✓ ExternalSecret synced"
else
  echo "✗ ExternalSecret not synced (status: $SECRET_STATUS)"
  exit 1
fi

# 4. HPA status
echo "\n[HPA]"
kubectl get hpa -n $NAMESPACE

echo "\n=== $SERVICE validation PASSED ==="
```

### Database Row Count Comparison

```bash
#!/bin/bash
# scripts/validation/compare-table-counts.sh

SOURCE_HOST=$1
TARGET_HOST=$2
DB_NAME=$3
TABLES=("orders" "order_items" "order_status_history")

echo "Comparing row counts: $SOURCE_HOST vs $TARGET_HOST"

PASS=true
for TABLE in "${TABLES[@]}"; do
  SOURCE_COUNT=$(psql -h $SOURCE_HOST -U postgres -d $DB_NAME -t -c \
    "SELECT COUNT(*) FROM public.$TABLE;")
  TARGET_COUNT=$(psql -h $TARGET_HOST -U postgres -d $DB_NAME -t -c \
    "SELECT COUNT(*) FROM order_service.$TABLE;")

  SOURCE_COUNT=$(echo $SOURCE_COUNT | tr -d ' ')
  TARGET_COUNT=$(echo $TARGET_COUNT | tr -d ' ')

  if [ "$SOURCE_COUNT" -eq "$TARGET_COUNT" ]; then
    echo "✓ $TABLE: $SOURCE_COUNT rows (match)"
  else
    echo "✗ $TABLE: source=$SOURCE_COUNT, target=$TARGET_COUNT (MISMATCH)"
    PASS=false
  fi
done

if $PASS; then
  echo "\nAll counts match. Safe to proceed."
  exit 0
else
  echo "\nRow count mismatch detected. DO NOT proceed with cutover."
  exit 1
fi
```

---

## Rollback Procedures

### Rollback: Traffic (immediate)

```bash
# Shift all traffic back to monolith immediately
cd terraform/environments/<env>
sed -i "s/^order_service_weight = .*/order_service_weight = 0/" terraform.tfvars
sed -i "s/^monolith_weight = .*/monolith_weight = 100/" terraform.tfvars
terraform apply -target=aws_lb_listener_rule.order_service_weighted -auto-approve

git add terraform/environments/<env>/terraform.tfvars
git commit -m "revert(migration): rollback traffic to monolith — <reason>"
```

### Rollback: Database (schema only)

```sql
-- If the service schema was just created and no data has been written to it
-- (reads still going to old tables), simply drop the new schema:
DROP SCHEMA order_service CASCADE;

-- If data HAS been written to both (dual-write scenario):
-- Disable dual-write in the application first
-- Then verify all recent writes are in the old schema
-- Then drop the new schema
```

### Rollback: Kubernetes Resources

```bash
# Roll back a specific deployment to previous version
kubectl rollout undo deployment/<service-name> -n <service-name>
kubectl rollout status deployment/<service-name> -n <service-name>

# Or roll back to a specific revision
kubectl rollout history deployment/<service-name> -n <service-name>
kubectl rollout undo deployment/<service-name> --to-revision=<N> -n <service-name>

# Record the rollback
git commit -m "revert(k8s): roll back <service-name> to previous version — <reason>"
```

### Rollback: Terraform (destroy specific resource)

```bash
# Only use this when you need to remove a resource that was incorrectly created
cd terraform/environments/<env>
terraform destroy -target=<resource_type>.<resource_name>
# Remove the Terraform code for that resource
git add terraform/
git commit -m "revert(terraform): remove <resource> — <reason>"
```

---

## Post-Migration Decommission Checklist

Only after a service has been running stably in production for **at least 2 weeks**:

- [ ] Zero error rate increase compared to monolith baseline
- [ ] Performance metrics within 10% of monolith baseline
- [ ] No P1/P2 incidents attributed to new service
- [ ] Old DB tables are no longer written to
- [ ] Old API routes in monolith returning 0 requests

Then:
1. Remove the old route from the load balancer
2. Remove the old code path from the monolith (PR to app repo)
3. After 2 more weeks, drop the old DB tables (migration script)
4. After all services are migrated, decommission the monolith EC2/ECS resources
5. Remove the monolith infrastructure from Terraform

```bash
git tag -a v1.0.0-<service>-decommissioned -m "<service> monolith code path decommissioned"
```

---

## Observability Setup

### CloudWatch Alarms (Terraform)

```hcl
resource "aws_cloudwatch_metric_alarm" "service_error_rate" {
  alarm_name          = "${local.name_prefix}-${var.service_name}-error-rate"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "HTTPCode_Target_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = "60"
  statistic           = "Sum"
  threshold           = "10"
  alarm_description   = "Error rate too high for ${var.service_name}"

  dimensions = {
    TargetGroup  = aws_lb_target_group.service.arn_suffix
    LoadBalancer = aws_lb.main.arn_suffix
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = local.common_tags
}
```

### Log Aggregation (Fluent Bit to CloudWatch)

```bash
# Install Fluent Bit via Helm
helm repo add fluent https://fluent.github.io/helm-charts
helm install fluent-bit fluent/fluent-bit \
  -n logging \
  --create-namespace \
  --set cloudWatch.enabled=true \
  --set cloudWatch.region=<region> \
  --set cloudWatch.logGroupName=/eks/<cluster-name>/containers \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=<fluent-bit-irsa-role-arn>
```
