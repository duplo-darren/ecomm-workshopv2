# Inventory Microservice

## Purpose

The Inventory microservice manages stock levels and warehouse information for products in the e-commerce application. It provides a RESTful API for tracking product quantities across warehouses.

## Responsibilities

- Product inventory management (stock quantities)
- Warehouse location tracking
- Inventory updates and queries by product ID
- Database schema management for inventory table

## Architecture

- **Framework**: Flask (Python web framework)
- **Database**: PostgreSQL
- **ORM**: SQLAlchemy
- **Dependencies**: None (standalone service)

## Database Schema

### Inventory Table

```sql
CREATE TABLE inventory (
    id SERIAL PRIMARY KEY,
    product_id INTEGER NOT NULL,
    quantity INTEGER NOT NULL DEFAULT 0,
    warehouse VARCHAR(100) DEFAULT 'main',
    updated_at TIMESTAMP DEFAULT (NOW() AT TIME ZONE 'utc')
);

CREATE INDEX ix_inventory_product_id ON inventory (product_id);
```

**Note**: `product_id` references products in the Catalog service, but there is NO foreign key constraint (microservices pattern - loose coupling).

## API Endpoints

All endpoints are prefixed with `/api`.

### List All Inventory
- **Method**: `GET`
- **Path**: `/api/inventory`
- **Response**: JSON array of all inventory records
- **Example**:
  ```json
  [
    {
      "id": 1,
      "product_id": 1,
      "quantity": 50,
      "warehouse": "main",
      "updated_at": "2024-01-01T00:00:00+00:00"
    }
  ]
  ```

### Get Inventory for Product
- **Method**: `GET`
- **Path**: `/api/inventory/<product_id>`
- **Response**: Inventory record for the specified product
- **Special Behavior**: If product has no inventory record, returns default:
  ```json
  {
    "product_id": 123,
    "quantity": 0,
    "warehouse": "main"
  }
  ```

### Update Inventory
- **Method**: `PUT`
- **Path**: `/api/inventory/<product_id>`
- **Content-Type**: `application/json`
- **Parameters**:
  - `quantity` (optional): New stock quantity
  - `warehouse` (optional): Warehouse location
- **Behavior**: Creates inventory record if it doesn't exist (upsert)
- **Response**: Updated inventory object
- **Example Request**:
  ```json
  {
    "quantity": 100,
    "warehouse": "warehouse-east"
  }
  ```

### Health Check
- **Method**: `GET`
- **Path**: `/health`
- **Response**: `{"status": "healthy"}`
- **Purpose**: Kubernetes liveness/readiness probe

## Configuration

### Required Environment Variables

#### Database Configuration (Choose One)

**Option 1: Direct Database URL**
```bash
DATABASE_URL=postgresql://username:password@host:5432/dbname
```

**Option 2: AWS Secrets Manager (Recommended for Production)**
```bash
DB_SECRET_NAME=path/to/secret      # Secrets Manager secret name
DB_NAME=dbinventory01              # Database name
AWS_REGION=us-east-1               # AWS region
```

**Secrets Manager Secret Format**:
```json
{
  "username": "db_user",
  "password": "db_password",
  "host": "db.example.com",
  "port": 5432
}
```

### Optional Environment Variables

```bash
FLASK_ENV=production               # Flask environment (development/production)
```

## Kubernetes Deployment Requirements

### Service Account & IAM (IRSA)

**Required IAM Permissions**:
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["secretsmanager:GetSecretValue"],
      "Resource": "arn:aws:secretsmanager:region:account:secret:path/to/inventory/secret-*"
    }
  ]
}
```

**Service Account Annotation**:
```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: inventory-sa
  namespace: your-namespace
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::ACCOUNT:role/inventory-role
```

### Deployment Configuration

**Example Deployment**:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: inventory-service
spec:
  replicas: 2
  template:
    spec:
      serviceAccountName: inventory-sa
      containers:
      - name: inventory
        image: your-registry/inventory:v1.0.0
        ports:
        - containerPort: 8002
        env:
        - name: DB_SECRET_NAME
          value: "path/to/inventory/secret"
        - name: DB_NAME
          value: "dbinventory01"
        - name: AWS_REGION
          value: "us-east-1"
        - name: FLASK_ENV
          value: "production"
        livenessProbe:
          httpGet:
            path: /health
            port: 8002
          initialDelaySeconds: 30
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /health
            port: 8002
          initialDelaySeconds: 10
          periodSeconds: 5
```

### Service Configuration

```yaml
apiVersion: v1
kind: Service
metadata:
  name: inventory-service
spec:
  selector:
    app: inventory
  ports:
  - protocol: TCP
    port: 8002
    targetPort: 8002
  type: ClusterIP
```

## Database Initialization

The service automatically creates tables on startup using SQLAlchemy:
```python
db.create_all()  # Creates inventory table if not exists
```

For migrations from existing data, use a Kubernetes Job or external migration script.

## Dependencies

See `requirements.txt`:
- Flask
- Flask-SQLAlchemy
- psycopg2-binary (PostgreSQL driver)
- boto3 (AWS SDK for Secrets Manager)
- gunicorn (WSGI server for production)

## Local Development

### Setup
```bash
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
```

### Run Locally
```bash
export DATABASE_URL=postgresql://ecomm:ecomm@localhost:5432/ecomm_inventory
python -m gunicorn -w 4 -b 0.0.0.0:8002 'inventory.app:create_app()'
```

### Run with Docker
```bash
docker build -t inventory-service .
docker run -p 8002:8002 \
  -e DATABASE_URL=postgresql://... \
  inventory-service
```

## Testing

### Health Check
```bash
curl http://localhost:8002/health
```

### List All Inventory
```bash
curl http://localhost:8002/api/inventory
```

### Get Inventory for Product
```bash
curl http://localhost:8002/api/inventory/1
```

### Update Inventory
```bash
curl -X PUT http://localhost:8002/api/inventory/1 \
  -H "Content-Type: application/json" \
  -d '{"quantity": 100, "warehouse": "warehouse-east"}'
```

## Troubleshooting

### Pod CrashLoopBackOff

**Symptom**: Pods continuously restart

**Common Causes**:
1. **Database connection failure**
   - Check `DB_SECRET_NAME` matches actual secret name
   - Verify `DB_NAME` is correct
   - Ensure RDS security group allows traffic from EKS nodes
   
2. **IAM permission issues**
   - Check service account has correct annotation
   - Verify IAM role trust policy includes correct namespace and service account
   - Confirm IAM role has `secretsmanager:GetSecretValue` permission

### Database Connection Errors

```bash
# Check if secret exists
kubectl get secret -n your-namespace

# View service account
kubectl describe serviceaccount inventory-sa -n your-namespace

# Check pod logs
kubectl logs -f deployment/inventory-service -n your-namespace
```

### Testing from Another Pod

```bash
# From frontend or another service
curl http://inventory-service.your-namespace.svc.cluster.local:8002/health
```

## Service Integration

### Consumed By
- **Frontend Service**: Queries inventory when displaying product details
- **Admin Interface**: Updates inventory levels

### Data Relationship
- `product_id` logically references products in the Catalog service
- No database-level foreign key constraint (microservices pattern)
- Frontend joins data at application layer

## Important Implementation Notes

1. **Namespace Consistency**: Ensure Kubernetes namespace matches IAM role trust policy
2. **Secret Name Format**: Use consistent naming between Terraform outputs and K8s manifests
3. **IAM Role ARN**: Service account annotation must match Terraform-created IAM role ARN
4. **Separate Database**: Inventory MUST use a separate database from Catalog (database-per-service pattern)
5. **Upsert Behavior**: PUT endpoint creates inventory record if it doesn't exist
6. **Default Warehouse**: If not specified, warehouse defaults to "main"
7. **Database Tables**: Created automatically on first startup
8. **Port**: Service must listen on port 8002 (hardcoded in multiple places)
9. **No S3 Dependency**: This service does not require S3 access (unlike Catalog)

## Database-per-Service Pattern

This service follows the microservices database-per-service pattern:
- **Own Database**: Has its own PostgreSQL database (`dbinventory01`)
- **No Direct DB Access**: Other services cannot directly query this database
- **API Contract**: All access through REST API endpoints
- **Data Consistency**: Eventually consistent with Catalog service
- **Schema Independence**: Can change schema without affecting other services

