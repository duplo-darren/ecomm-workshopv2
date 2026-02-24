# Catalog Microservice

## Purpose

The Catalog microservice manages the product catalog for the e-commerce application. It provides a RESTful API for creating, reading, updating, and deleting products, including product images.

## Responsibilities

- Product CRUD operations (Create, Read, Update, Delete)
- Product image storage and retrieval
- Product metadata management (name, description, price)
- Database schema management for products table

## Architecture

- **Framework**: Flask (Python web framework)
- **Database**: PostgreSQL
- **ORM**: SQLAlchemy
- **Storage**: Dual-mode (Local filesystem or AWS S3)

## Database Schema

### Products Table

```sql
CREATE TABLE products (
    id SERIAL PRIMARY KEY,
    name VARCHAR(200) NOT NULL,
    description TEXT DEFAULT '',
    price DOUBLE PRECISION NOT NULL,
    image_path VARCHAR(500) DEFAULT '',
    created_at TIMESTAMP DEFAULT (NOW() AT TIME ZONE 'utc')
);
```

## API Endpoints

All endpoints are prefixed with `/api`.

### List Products
- **Method**: `GET`
- **Path**: `/api/products`
- **Response**: JSON array of product objects with image URLs
- **Example**:
  ```json
  [
    {
      "id": 1,
      "name": "Wireless Headphones",
      "description": "Premium wireless headphones",
      "price": 149.99,
      "image_path": "uploads/abc123.jpg",
      "image_url": "https://bucket.s3.amazonaws.com/uploads/abc123.jpg",
      "created_at": "2024-01-01T00:00:00+00:00"
    }
  ]
  ```

### Get Product by ID
- **Method**: `GET`
- **Path**: `/api/products/<product_id>`
- **Response**: Single product object
- **Error**: 404 if product not found

### Create Product
- **Method**: `POST`
- **Path**: `/api/products`
- **Content-Type**: `multipart/form-data`
- **Parameters**:
  - `name` (required): Product name
  - `description` (optional): Product description
  - `price` (required): Product price (float)
  - `image` (optional): Image file upload
- **Response**: Created product object (201)

### Update Product
- **Method**: `PUT`
- **Path**: `/api/products/<product_id>`
- **Content-Type**: `application/json`
- **Parameters**:
  - `name` (optional): Updated product name
  - `description` (optional): Updated description
  - `price` (optional): Updated price
- **Note**: Image updates are not supported via this endpoint
- **Response**: Updated product object

### Delete Product
- **Method**: `DELETE`
- **Path**: `/api/products/<product_id>`
- **Response**: `{"message": "Product deleted"}`
- **Side Effect**: Deletes associated image from storage

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
DB_NAME=dbcatalog01                # Database name
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

#### Storage Configuration

**Local Storage (Development)**
```bash
# No additional environment variables needed
# Images stored in ./static/uploads/
```

**S3 Storage (Production)**
```bash
USE_OBJECT_STORAGE=true
OBJECT_STORE_LOCATION=my-bucket-name
AWS_REGION=us-east-1
```

### Optional Environment Variables

```bash
FLASK_ENV=production               # Flask environment (development/production)
```

## Storage Modes

### Local Storage Mode
- **When**: `USE_OBJECT_STORAGE` is not set or false
- **Behavior**: 
  - Images saved to `./static/uploads/`
  - Image URLs: `/static/uploads/filename.jpg`
  - Requires persistent volume in Kubernetes

### S3 Storage Mode
- **When**: `USE_OBJECT_STORAGE=true` and `OBJECT_STORE_LOCATION` is set
- **Behavior**:
  - Images uploaded to S3 bucket
  - Image URLs: `https://bucket-name.s3.amazonaws.com/uploads/filename.jpg`
  - Requires IAM permissions for S3 access

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
      "Resource": "arn:aws:secretsmanager:region:account:secret:path/to/catalog/secret-*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject",
        "s3:DeleteObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::bucket-name",
        "arn:aws:s3:::bucket-name/*"
      ]
    }
  ]
}
```

**Service Account Annotation**:
```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: catalog-sa
  namespace: your-namespace
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::ACCOUNT:role/catalog-role
```



## Database Initialization

The service automatically creates tables on startup using SQLAlchemy:
```python
db.create_all()  # Creates products table if not exists
```

For migrations from existing data, use a Kubernetes Job or external migration script.

## Dependencies

See `requirements.txt`:
- Flask
- Flask-SQLAlchemy
- psycopg2-binary (PostgreSQL driver)
- boto3 (AWS SDK for S3 and Secrets Manager)
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
export DATABASE_URL=postgresql://ecomm:ecomm@localhost:5432/ecomm_catalog
python -m gunicorn -w 4 -b 0.0.0.0:8001 'catalog.app:create_app()'
```

### Run with Docker
```bash
docker build -t catalog-service .
docker run -p 8001:8001 \
  -e DATABASE_URL=postgresql://... \
  catalog-service
```

## Testing

### Health Check
```bash
curl http://localhost:8001/health
```

### List Products
```bash
curl http://localhost:8001/api/products
```

### Create Product
```bash
curl -X POST http://localhost:8001/api/products \
  -F "name=Test Product" \
  -F "description=Test Description" \
  -F "price=99.99" \
  -F "image=@/path/to/image.jpg"
```


