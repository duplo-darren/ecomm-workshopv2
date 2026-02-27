# Reference: Monolith Analysis

## Goal

Produce a complete, factual picture of the monolith before touching any infrastructure. You
cannot design good service boundaries without understanding what you're working with. Invest
real time here — mistakes caught in analysis cost nothing; mistakes caught in production cost
everything.

---

## Tooling for Code Analysis

```bash
# Install cloc for line-count and language breakdown
sudo apt-get install -y cloc   # or: brew install cloc

# Install tree for directory visualization
sudo apt-get install -y tree   # or: brew install tree

# Python tools for deeper analysis
pip install ast-grep pygments radon
```

---

## Step 1: Language and Size Inventory

```bash
# Total lines of code by language
cloc <repo-path> --exclude-dir=node_modules,vendor,.git

# Directory tree (3 levels deep)
tree -L 3 -I 'node_modules|vendor|.git|*.pyc|__pycache__' <repo-path>

# Find all configuration files
find <repo-path> -name "*.env*" -o -name "*.yaml" -o -name "*.yml" \
  -o -name "*.toml" -o -name "*.ini" -o -name "*.conf" | \
  grep -v node_modules | grep -v .git | sort
```

---

## Step 2: API Surface Mapping

### For REST APIs

```bash
# Find route definitions (adjust patterns to match framework)
# Express.js
grep -rn "app\.\(get\|post\|put\|patch\|delete\)\|router\.\(get\|post\|put\|patch\|delete\)" \
  <repo-path> --include="*.js" --include="*.ts" | grep -v node_modules

# Django
grep -rn "path\|url\|re_path" <repo-path> --include="urls.py"

# Spring Boot
grep -rn "@GetMapping\|@PostMapping\|@PutMapping\|@DeleteMapping\|@RequestMapping" \
  <repo-path> --include="*.java"

# Rails
cat <repo-path>/config/routes.rb

# FastAPI / Flask
grep -rn "@app\.route\|@router\." <repo-path> --include="*.py"

# Go / Gin / Chi
grep -rn "\.GET\|\.POST\|\.PUT\|\.DELETE\|\.Handle\|\.HandleFunc" \
  <repo-path> --include="*.go"
```

### For gRPC
```bash
find <repo-path> -name "*.proto" | xargs grep -l "rpc "
```

### For message queues / events
```bash
# SQS / SNS references
grep -rn "SQS\|SNS\|sqs\|sns\|send_message\|publish\|subscribe\|consume" \
  <repo-path> --include="*.py" --include="*.js" --include="*.ts" --include="*.java" --include="*.go"

# Kafka
grep -rn "kafka\|KafkaProducer\|KafkaConsumer\|@KafkaListener" <repo-path>

# RabbitMQ
grep -rn "rabbit\|pika\|amqp\|channel\.basic_publish\|channel\.basic_consume" <repo-path>
```

---

## Step 3: Database Schema Analysis

```bash
# Find migration files
find <repo-path> -type d -name "migrations" -o -name "db" -o -name "schema"

# Look for ORM model definitions
# Django
find <repo-path> -name "models.py" | xargs grep -l "class.*Model"

# SQLAlchemy
grep -rn "class.*Base\|Column\|relationship" <repo-path> --include="*.py"

# ActiveRecord (Rails)
find <repo-path>/app/models -name "*.rb"

# TypeORM / Prisma
find <repo-path> -name "*.entity.ts" -o -name "schema.prisma"

# Hibernate / JPA
grep -rn "@Entity\|@Table\|@Column\|@ManyToOne\|@OneToMany" <repo-path> --include="*.java"

# GORM
grep -rn "gorm.Model\|has_many\|belongs_to" <repo-path> --include="*.go"
```

### Direct schema dump (if you have DB access)
```bash
# PostgreSQL
pg_dump --schema-only -d <dbname> -U <user> -h <host> > docs/architecture/schema-dump.sql

# Extract table list with column counts
psql -U <user> -h <host> -d <dbname> -c "
  SELECT table_name, COUNT(column_name) as col_count
  FROM information_schema.columns
  WHERE table_schema = 'public'
  GROUP BY table_name
  ORDER BY table_name;
"

# Extract foreign key relationships
psql -U <user> -h <host> -d <dbname> -c "
  SELECT
    tc.table_name AS source_table,
    kcu.column_name AS source_column,
    ccu.table_name AS target_table,
    ccu.column_name AS target_column
  FROM information_schema.table_constraints tc
  JOIN information_schema.key_column_usage kcu ON tc.constraint_name = kcu.constraint_name
  JOIN information_schema.constraint_column_usage ccu ON tc.constraint_name = ccu.constraint_name
  WHERE tc.constraint_type = 'FOREIGN KEY'
  ORDER BY source_table;
"
```

---

## Step 4: Dependency and Module Mapping

```bash
# Python: internal imports
grep -rn "^from \.\|^import \." <repo-path> --include="*.py" | \
  awk '{print $2}' | sort | uniq -c | sort -rn | head -50

# Node.js: local requires/imports
grep -rn "require\('\.\|from '\." <repo-path> --include="*.js" --include="*.ts" | \
  grep -v node_modules | grep -v ".test." | \
  awk -F"['\"]" '{print $2}' | sort | uniq -c | sort -rn | head -50

# Java: package dependencies
grep -rn "^import " <repo-path> --include="*.java" | \
  grep -v "java\.\|org\.springframework\|javax\." | \
  awk '{print $2}' | sort | uniq -c | sort -rn | head -50

# Go: internal imports
grep -rn '"<module-path>/' <repo-path> --include="*.go" | \
  awk -F'"' '{print $2}' | sort | uniq -c | sort -rn | head -50
```

---

## Step 5: Current AWS Infrastructure Discovery

```bash
# What's currently running in AWS
aws ec2 describe-instances --query 'Reservations[*].Instances[*].[InstanceId,InstanceType,State.Name,Tags[?Key==`Name`].Value|[0]]' --output table
aws rds describe-db-instances --query 'DBInstances[*].[DBInstanceIdentifier,Engine,EngineVersion,DBInstanceClass,DBInstanceStatus]' --output table
aws s3 ls
aws elbv2 describe-load-balancers --query 'LoadBalancers[*].[LoadBalancerName,Type,State.Code]' --output table
aws ecr describe-repositories --query 'repositories[*].[repositoryName,repositoryUri]' --output table
aws eks list-clusters

# Security groups in use
aws ec2 describe-security-groups --query 'SecurityGroups[*].[GroupId,GroupName,Description]' --output table

# Current IAM roles (application-related)
aws iam list-roles --query 'Roles[?contains(RoleName, `app`) || contains(RoleName, `service`) || contains(RoleName, `<project>`)].[RoleName,Arn]' --output table
```

---

## Step 6: Cron Jobs and Background Workers

```bash
# Cron expressions
grep -rn "cron\|schedule\|@Scheduled\|celery\|beat\|sidekiq\|resque\|bull" \
  <repo-path> --include="*.py" --include="*.java" --include="*.rb" --include="*.js" --include="*.ts"

# Systemd timers or crontab
find <repo-path> -name "*.cron" -o -name "crontab" -o -name "*.timer"
```

---

## Analysis Output Template

Produce `docs/architecture/02-component-map.md` using this template:

```markdown
# Component Map

## Summary
- Total components identified: N
- Languages: Python 60%, Go 40%
- Total LOC: ~N

## Components

### <Component Name>
- **Location**: `src/billing/`
- **Responsibility**: Handles invoice generation and payment processing
- **Type**: Background Worker | API Handler | Cron Job | Event Consumer
- **Key files**: `billing_service.py`, `invoice_generator.py`
- **Owns tables**: `invoices`, `payments`, `billing_addresses`
- **Calls internally**: AuthModule, UserModule
- **External calls**: Stripe API, SendGrid
- **Config required**: STRIPE_API_KEY, SENDGRID_API_KEY

...
```

---

## Bounded Context Heuristics

When grouping components into microservices, apply these rules:

1. **Data ownership is the primary driver** — if two components always JOIN the same tables, they likely belong in the same service
2. **Change rate** — components that change together should stay together
3. **Team ownership** — if different teams own different parts, those are natural service boundaries
4. **Transaction boundaries** — operations that must be atomic (all succeed or all fail together) should stay in one service
5. **Avoid chatty services** — if extracting a service would require hundreds of synchronous API calls per second between it and the monolith, the boundary is probably wrong
6. **Start coarse, refine later** — it's easier to split one service into two than to merge two services back together

## Red Flags to Document

Note these as risks requiring attention:
- **God tables** — tables with 50+ columns touched by many components
- **Shared mutable state** — global config, feature flags written/read across components
- **Distributed transactions** — operations that span what would be multiple service boundaries and need to be atomic
- **Tight coupling hotspots** — modules with 10+ internal imports from other modules
