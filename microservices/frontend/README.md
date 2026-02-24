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

## Database Schema# Frontend Microservice

## Purpose

The Frontend microservice provides the user-facing web interface for the e-commerce application. It aggregates data from backend microservices (Catalog and Inventory) and renders HTML pages for end users.

## Responsibilities

- Render product listing pages
- Display product details with inventory information
- Provide admin interface for product management
- Orchestrate calls to Catalog and Inventory services
- Handle form submissions for product creation and inventory updates

## Architecture

- **Framework**: Flask (Python web framework)
- **Template Engine**: Jinja2
- **Service Communication**: HTTP REST (via ServiceClient)
- **Database**: None (stateless - aggregates data from other services)

## Architecture Pattern

This service implements the **API Gateway / Backend for Frontend (BFF)** pattern:
- Aggregates data from multiple backend services
- Provides unified view layer
- Handles service orchestration
- No direct database access

## Pages & Routes

### Public Pages

#### Home Page
- **Path**: `/`
- **Method**: GET
- **Purpose**: Display list of all products
- **Data Sources**: Catalog service (`/api/products`)
- **Template**: `templates/index.html`

#### Product Detail
- **Path**: `/products/<product_id>`
- **Method**: GET
- **Purpose**: Show product details with inventory information
- **Data Sources**: 
  - Catalog service (`/api/products/<id>`)
  - Inventory service (`/api/inventory/<id>`)
- **Template**: `templates/product.html`

### Admin Pages

#### Admin Dashboard
- **Path**: `/admin`
- **Method**: GET
- **Purpose**: Manage products (list and add)
- **Data Sources**: Catalog service (`/api/products`)
- **Template**: `templates/admin.html`

#### Add Product
- **Path**: `/admin/add-product`
- **Method**: POST
- **Purpose**: Create new product with image upload
- **Target**: Catalog service (`POST /api/products`)
- **Parameters**: 
  - `name` (required)
  - `description` (optional)
  - `price` (required)
  - `image` (optional file upload)
- **Redirect**: Back to `/admin` after success

#### Update Inventory
- **Path**: `/products/<product_id>/inventory`
- **Method**: POST
- **Purpose**: Update stock quantity and warehouse
- **Target**: Inventory service (`PUT /api/inventory/<id>`)
- **Parameters**:
  - `quantity` (required)
  - `warehouse` (optional)
- **Redirect**: Back to product detail page

### Health Check
- **Method**: GET
- **Path**: `/health`
- **Response**: `{"status": "healthy"}`
- **Purpose**: Kubernetes liveness/readiness probe

## Service Communication

### ServiceClient

The `ServiceClient` class provides HTTP-based communication with backend services:

```python
# Get data from Catalog service
products = ServiceClient.get("catalog", "/api/products")

# Get data from Inventory service
inventory = ServiceClient.get("inventory", f"/api/inventory/{product_id}")

# Create product in Catalog service
ServiceClient.post("catalog", "/api/products", data=form_data, files=files)

# Update inventory
ServiceClient.put("inventory", f"/api/inventory/{product_id}", json=data)
```

### Service Discovery

Services are discovered via environment variables:
- `CATALOG_SERVICE_URL`: Full URL to Catalog service
- `INVENTORY_SERVICE_URL`: Full URL to Inventory service

## Configuration

### Required Environment Variables

```bash
CATALOG_SERVICE_URL=http://catalog-service:8001
INVENTORY_SERVICE_URL=http://inventory-service:8002
```

### Optional Environment Variables

```bash
FLASK_ENV=production               # Flask environment (development/production)
```


## Local Development

### Setup
```bash
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
```

### Run Locally (with Backend Services)
```bash
# Ensure Catalog and Inventory services are running
export CATALOG_SERVICE_URL=http://localhost:8001
export INVENTORY_SERVICE_URL=http://localhost:8002
python -m gunicorn -w 4 -b 0.0.0.0:8000 'frontend.app:create_app()'
```

### Run with Docker
```bash
docker build -t frontend-service .
docker run -p 8000:8000 \
  -e CATALOG_SERVICE_URL=http://catalog-service:8001 \
  -e INVENTORY_SERVICE_URL=http://inventory-service:8002 \
  frontend-service
```

## Testing

### Health Check
```bash
curl http://localhost:8000/health
```

### Home Page
```bash
curl http://localhost:8000/
```

### Admin Page
```bash
curl http://localhost:8000/admin
```

## Error Handling

### Backend Service Unavailable

If Catalog or Inventory services are unreachable, the frontend will:
- Raise `requests.exceptions.RequestException`
- Return HTTP 500 error to the user
- Log error details

**Error Scenarios**:
- Service DNS not resolving
- Service not responding (timeout)
- Backend returns 4xx/5xx error

**Mitigation**:
- Ensure service URLs are correct
- Verify backend services are healthy
- Check network policies allow communication
- Implement retry logic or circuit breaker (future enhancement)

