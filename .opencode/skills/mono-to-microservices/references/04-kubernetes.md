# Reference: Kubernetes on EKS

## Namespace Strategy

Each service gets its own namespace. This provides RBAC boundaries, resource quotas, and
network policy scope.

```bash
# Create namespace (also do this in Terraform or Kustomize)
kubectl create namespace <service-name>
kubectl label namespace <service-name> \
  project=<project> \
  environment=<env> \
  managed-by=terraform
```

In Terraform:
```hcl
resource "kubernetes_namespace" "services" {
  for_each = toset(var.service_names)

  metadata {
    name = each.value
    labels = {
      project     = var.project
      environment = var.environment
      "managed-by" = "terraform"
    }
  }
}
```

---

## Standard Service Manifests

### Deployment

```yaml
# kubernetes/services/<name>/base/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: <service-name>
  namespace: <service-name>
  labels:
    app: <service-name>
    version: "1.0.0"
spec:
  replicas: 2
  selector:
    matchLabels:
      app: <service-name>
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0  # zero-downtime deployments
  template:
    metadata:
      labels:
        app: <service-name>
        version: "1.0.0"
      annotations:
        # Force pod restart when secrets change
        checksum/secrets: "{{ include (print $.Template.BasePath \"/externalsecret.yaml\") . | sha256sum }}"
    spec:
      serviceAccountName: <service-name>-sa
      terminationGracePeriodSeconds: 60

      # Pod anti-affinity: spread pods across AZs
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            podAffinityTerm:
              labelSelector:
                matchExpressions:
                - key: app
                  operator: In
                  values: [<service-name>]
              topologyKey: topology.kubernetes.io/zone

      containers:
      - name: <service-name>
        image: <ecr-url>/<project>/<service-name>:latest
        imagePullPolicy: Always
        ports:
        - containerPort: 8080
          name: http
          protocol: TCP

        # Resource requests and limits — tune these based on profiling
        resources:
          requests:
            cpu: "250m"
            memory: "256Mi"
          limits:
            cpu: "1000m"
            memory: "512Mi"

        # Environment variables from Secrets Manager (via External Secrets)
        envFrom:
        - secretRef:
            name: <service-name>-secrets

        # Direct env vars (non-secret)
        env:
        - name: APP_ENV
          value: "<environment>"
        - name: LOG_LEVEL
          value: "info"
        - name: DB_HOST
          valueFrom:
            configMapKeyRef:
              name: <service-name>-config
              key: db_host
        - name: AWS_DEFAULT_REGION
          value: "<region>"

        # Health checks
        livenessProbe:
          httpGet:
            path: /health/live
            port: 8080
          initialDelaySeconds: 30
          periodSeconds: 10
          failureThreshold: 3
          timeoutSeconds: 5

        readinessProbe:
          httpGet:
            path: /health/ready
            port: 8080
          initialDelaySeconds: 10
          periodSeconds: 5
          failureThreshold: 3
          timeoutSeconds: 3

        startupProbe:
          httpGet:
            path: /health/live
            port: 8080
          failureThreshold: 30
          periodSeconds: 10

        # Graceful shutdown
        lifecycle:
          preStop:
            exec:
              command: ["/bin/sh", "-c", "sleep 15"]

      # Security context — run as non-root
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        fsGroup: 1000
```

### Service

```yaml
# kubernetes/services/<name>/base/service.yaml
apiVersion: v1
kind: Service
metadata:
  name: <service-name>
  namespace: <service-name>
  labels:
    app: <service-name>
spec:
  type: ClusterIP  # internal only; ALB handles external traffic
  selector:
    app: <service-name>
  ports:
  - name: http
    port: 80
    targetPort: 8080
    protocol: TCP
```

### ServiceAccount (for IRSA)

```yaml
# kubernetes/services/<name>/base/serviceaccount.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: <service-name>-sa
  namespace: <service-name>
  annotations:
    # This annotation binds to the IAM role created by Terraform
    eks.amazonaws.com/role-arn: arn:aws:iam::<account-id>:role/<project>-<env>-<service-name>-irsa
  labels:
    app: <service-name>
```

### HorizontalPodAutoscaler

```yaml
# kubernetes/services/<name>/base/hpa.yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: <service-name>-hpa
  namespace: <service-name>
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: <service-name>
  minReplicas: 2
  maxReplicas: 10
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70
  - type: Resource
    resource:
      name: memory
      target:
        type: Utilization
        averageUtilization: 80
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 300  # wait 5 min before scaling down
      policies:
      - type: Pods
        value: 1
        periodSeconds: 60
    scaleUp:
      stabilizationWindowSeconds: 0
      policies:
      - type: Pods
        value: 2
        periodSeconds: 60
```

### ConfigMap

```yaml
# kubernetes/services/<name>/base/configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: <service-name>-config
  namespace: <service-name>
data:
  db_host: "<rds-endpoint>"
  db_port: "5432"
  db_name: "<service_schema>"
  s3_bucket: "<project>-<service>-assets-<env>"
  app_port: "8080"
```

### PodDisruptionBudget

```yaml
# kubernetes/services/<name>/base/pdb.yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: <service-name>-pdb
  namespace: <service-name>
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: <service-name>
```

### NetworkPolicy

```yaml
# kubernetes/services/<name>/base/networkpolicy.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: <service-name>-netpol
  namespace: <service-name>
spec:
  podSelector:
    matchLabels:
      app: <service-name>
  policyTypes:
  - Ingress
  - Egress
  ingress:
  # Allow from ingress controller (ALB)
  - from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: kube-system
    ports:
    - port: 8080
  # Allow from other specific services
  - from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: api-gateway
    ports:
    - port: 8080
  egress:
  # Allow DNS
  - to:
    - namespaceSelector: {}
    ports:
    - port: 53
      protocol: UDP
  # Allow outbound to RDS (port 5432)
  - to:
    - ipBlock:
        cidr: 10.0.0.0/16  # VPC CIDR
    ports:
    - port: 5432
  # Allow HTTPS for AWS APIs (S3, Secrets Manager, etc.)
  - to:
    - ipBlock:
        cidr: 0.0.0.0/0
    ports:
    - port: 443
```

---

## Kustomize Structure

```yaml
# kubernetes/services/<name>/base/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
- deployment.yaml
- service.yaml
- serviceaccount.yaml
- hpa.yaml
- configmap.yaml
- pdb.yaml
- networkpolicy.yaml
- externalsecret.yaml
```

```yaml
# kubernetes/services/<name>/overlays/dev/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

bases:
- ../../base

patches:
- path: deployment-patch.yaml
  target:
    kind: Deployment
    name: <service-name>
```

```yaml
# kubernetes/services/<name>/overlays/dev/deployment-patch.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: <service-name>
spec:
  replicas: 1  # lower in dev
  template:
    spec:
      containers:
      - name: <service-name>
        resources:
          requests:
            cpu: "100m"
            memory: "128Mi"
          limits:
            cpu: "500m"
            memory: "256Mi"
```

---

## Dockerfile Best Practices

```dockerfile
# Multi-stage build example (Node.js)
FROM node:20-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci --only=production

FROM node:20-alpine
# Non-root user
RUN addgroup -g 1001 -S nodejs && adduser -S nodeapp -u 1001

WORKDIR /app
COPY --from=builder --chown=nodeapp:nodejs /app/node_modules ./node_modules
COPY --chown=nodeapp:nodejs . .

USER nodeapp
EXPOSE 8080

# Health check baked in
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD wget -qO- http://localhost:8080/health/live || exit 1

CMD ["node", "server.js"]
```

```dockerfile
# Python example
FROM python:3.12-slim AS base

RUN groupadd -r appuser && useradd -r -g appuser appuser

WORKDIR /app

FROM base AS dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

FROM base
COPY --from=dependencies /usr/local/lib/python3.12/site-packages /usr/local/lib/python3.12/site-packages
COPY --chown=appuser:appuser . .

USER appuser
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8080/health/live')"

CMD ["gunicorn", "-w", "4", "-b", "0.0.0.0:8080", "app:app"]
```

---

## Health Check Endpoint Requirements

Every service MUST implement these two endpoints:

```
GET /health/live   → 200 if the process is running (liveness)
GET /health/ready  → 200 if the service can accept traffic (readiness)
                     (checks DB connection, cache connection, etc.)
```

The readiness check should return 503 if any critical dependency is unavailable. This prevents
traffic from being routed to a pod that can't serve requests.

---

## kubectl Commands Reference

```bash
# View all resources in a namespace
kubectl get all -n <service-name>

# Describe a pod (see events, resource limits)
kubectl describe pod -n <service-name> <pod-name>

# View logs (last 100 lines, follow)
kubectl logs -n <service-name> -l app=<service-name> --tail=100 -f

# Exec into a pod for debugging
kubectl exec -it -n <service-name> <pod-name> -- /bin/sh

# Port-forward for local testing
kubectl port-forward -n <service-name> svc/<service-name> 8080:80

# Roll out a new image
kubectl set image deployment/<service-name> <service-name>=<ecr-url>/<image>:<new-tag> -n <service-name>
kubectl rollout status deployment/<service-name> -n <service-name>

# Roll back a deployment
kubectl rollout undo deployment/<service-name> -n <service-name>

# View rollout history
kubectl rollout history deployment/<service-name> -n <service-name>

# Scale manually (for emergencies)
kubectl scale deployment/<service-name> --replicas=5 -n <service-name>

# View HPA status
kubectl get hpa -n <service-name>
kubectl describe hpa <service-name>-hpa -n <service-name>

# Apply kustomize overlay
kubectl apply -k kubernetes/services/<service-name>/overlays/<env>

# Dry run (validate without applying)
kubectl apply -k kubernetes/services/<service-name>/overlays/<env> --dry-run=client

# Diff (show what will change)
kubectl diff -k kubernetes/services/<service-name>/overlays/<env>

# Get events (sorted by time)
kubectl get events -n <service-name> --sort-by='.lastTimestamp'
```

---

## Cluster-Wide Components Setup

```bash
# After EKS is provisioned, install cluster-level components:

# 1. Update kubeconfig
aws eks update-kubeconfig --region <region> --name <project>-<env>-cluster

# 2. Verify AWS Load Balancer Controller is running
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller

# 3. Verify External Secrets Operator
kubectl get pods -n external-secrets-system

# 4. Create ClusterSecretStore (connects ESO to AWS Secrets Manager)
cat <<EOF | kubectl apply -f -
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: aws-secrets-store
spec:
  provider:
    aws:
      service: SecretsManager
      region: <region>
      auth:
        jwt:
          serviceAccountRef:
            name: external-secrets-sa
            namespace: external-secrets-system
EOF

# 5. Verify metrics server
kubectl top nodes
kubectl top pods --all-namespaces
```
