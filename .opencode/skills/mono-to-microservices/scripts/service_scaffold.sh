#!/bin/bash
# =============================================================================
# Service Scaffold Generator
# Creates the standard directory structure and base Kubernetes manifests
# for a new microservice.
#
# Usage:
#   bash scripts/service_scaffold.sh <service-name> <namespace> <env> \
#     [--expose none|internal|external]
#
# Examples:
#   bash scripts/service_scaffold.sh user-service user-service dev --expose internal
#   bash scripts/service_scaffold.sh order-service order-service dev --expose external
#   bash scripts/service_scaffold.sh background-worker background-worker dev --expose none
# =============================================================================

set -euo pipefail

SERVICE_NAME="${1:?Usage: $0 <service-name> <namespace> <env> [--expose none|internal|external]}"
NAMESPACE="${2:?Missing namespace}"
ENV="${3:?Missing environment}"
EXPOSE="none"

# Parse optional --expose flag
while [[ $# -gt 3 ]]; do
  case "$4" in
    --expose)
      EXPOSE="${5:?--expose requires a value: none|internal|external}"
      shift 2
      ;;
    *) shift ;;
  esac
done

# Validate expose value
if [[ "$EXPOSE" != "none" && "$EXPOSE" != "internal" && "$EXPOSE" != "external" ]]; then
  echo "ERROR: --expose must be one of: none, internal, external"
  exit 1
fi

echo "==================================================="
echo "  Scaffolding service: $SERVICE_NAME"
echo "  Namespace:           $NAMESPACE"
echo "  Environment:         $ENV"
echo "  Exposure:            $EXPOSE"
echo "==================================================="
echo ""

BASE_DIR="kubernetes/services/${SERVICE_NAME}"

# Create directory structure
mkdir -p \
  "${BASE_DIR}/base" \
  "${BASE_DIR}/overlays/dev" \
  "${BASE_DIR}/overlays/staging" \
  "${BASE_DIR}/overlays/prod"

# =============================================================================
# base/deployment.yaml
# =============================================================================
cat > "${BASE_DIR}/base/deployment.yaml" << EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${SERVICE_NAME}
  namespace: ${NAMESPACE}
  labels:
    app: ${SERVICE_NAME}
spec:
  replicas: 2
  selector:
    matchLabels:
      app: ${SERVICE_NAME}
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  template:
    metadata:
      labels:
        app: ${SERVICE_NAME}
    spec:
      serviceAccountName: ${SERVICE_NAME}-sa
      terminationGracePeriodSeconds: 60
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            podAffinityTerm:
              labelSelector:
                matchExpressions:
                - key: app
                  operator: In
                  values: [${SERVICE_NAME}]
              topologyKey: topology.kubernetes.io/zone
      containers:
      - name: ${SERVICE_NAME}
        # TODO: Replace with actual ECR image URL
        image: PLACEHOLDER_ECR_URL/${SERVICE_NAME}:latest
        imagePullPolicy: Always
        ports:
        - containerPort: 8080
          name: http
          protocol: TCP
        resources:
          requests:
            cpu: "250m"
            memory: "256Mi"
          limits:
            cpu: "1000m"
            memory: "512Mi"
        envFrom:
        - secretRef:
            name: ${SERVICE_NAME}-secrets
        - configMapRef:
            name: ${SERVICE_NAME}-config
        env:
        - name: APP_ENV
          value: "PLACEHOLDER_ENV"
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
        lifecycle:
          preStop:
            exec:
              command: ["/bin/sh", "-c", "sleep 15"]
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        fsGroup: 1000
EOF

# =============================================================================
# base/service.yaml
# =============================================================================
cat > "${BASE_DIR}/base/service.yaml" << EOF
apiVersion: v1
kind: Service
metadata:
  name: ${SERVICE_NAME}
  namespace: ${NAMESPACE}
  labels:
    app: ${SERVICE_NAME}
spec:
  type: ClusterIP
  selector:
    app: ${SERVICE_NAME}
  ports:
  - name: http
    port: 80
    targetPort: 8080
    protocol: TCP
EOF

# =============================================================================
# base/serviceaccount.yaml
# =============================================================================
cat > "${BASE_DIR}/base/serviceaccount.yaml" << EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${SERVICE_NAME}-sa
  namespace: ${NAMESPACE}
  annotations:
    # TODO: Replace with actual IRSA role ARN from Terraform output
    eks.amazonaws.com/role-arn: PLACEHOLDER_IRSA_ROLE_ARN
  labels:
    app: ${SERVICE_NAME}
EOF

# =============================================================================
# base/hpa.yaml
# =============================================================================
cat > "${BASE_DIR}/base/hpa.yaml" << EOF
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: ${SERVICE_NAME}-hpa
  namespace: ${NAMESPACE}
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: ${SERVICE_NAME}
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
      stabilizationWindowSeconds: 300
    scaleUp:
      stabilizationWindowSeconds: 0
EOF

# =============================================================================
# base/configmap.yaml
# =============================================================================
cat > "${BASE_DIR}/base/configmap.yaml" << EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${SERVICE_NAME}-config
  namespace: ${NAMESPACE}
data:
  # TODO: Fill in actual values
  APP_PORT: "8080"
  LOG_LEVEL: "info"
  DB_HOST: "PLACEHOLDER_RDS_ENDPOINT"
  DB_PORT: "5432"
  DB_NAME: "${SERVICE_NAME//-/_}"
EOF

# =============================================================================
# base/pdb.yaml
# =============================================================================
cat > "${BASE_DIR}/base/pdb.yaml" << EOF
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: ${SERVICE_NAME}-pdb
  namespace: ${NAMESPACE}
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: ${SERVICE_NAME}
EOF

# =============================================================================
# base/networkpolicy.yaml
# =============================================================================
cat > "${BASE_DIR}/base/networkpolicy.yaml" << EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: ${SERVICE_NAME}-netpol
  namespace: ${NAMESPACE}
spec:
  podSelector:
    matchLabels:
      app: ${SERVICE_NAME}
  policyTypes:
  - Ingress
  - Egress
  ingress:
  # Allow from ingress controller
  - from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: kube-system
    ports:
    - port: 8080
  egress:
  # Allow DNS
  - to:
    - namespaceSelector: {}
    ports:
    - port: 53
      protocol: UDP
  # Allow outbound to VPC (RDS, etc.)
  - to:
    - ipBlock:
        cidr: 10.0.0.0/8
    ports:
    - port: 5432
    - port: 443
  # Allow HTTPS for AWS APIs
  - to:
    - ipBlock:
        cidr: 0.0.0.0/0
    ports:
    - port: 443
EOF

# =============================================================================
# base/externalsecret.yaml
# =============================================================================
cat > "${BASE_DIR}/base/externalsecret.yaml" << EOF
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: ${SERVICE_NAME}-secrets
  namespace: ${NAMESPACE}
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: aws-secrets-store
    kind: ClusterSecretStore
  target:
    name: ${SERVICE_NAME}-secrets
    creationPolicy: Owner
  data:
  # TODO: Add actual secret keys for this service
  - secretKey: DB_PASSWORD
    remoteRef:
      key: /PLACEHOLDER_PROJECT/PLACEHOLDER_ENV/${SERVICE_NAME}/db-password
EOF

# =============================================================================
# base/kustomization.yaml
# =============================================================================
KUSTOMIZE_RESOURCES="- deployment.yaml
- service.yaml
- serviceaccount.yaml
- hpa.yaml
- configmap.yaml
- pdb.yaml
- networkpolicy.yaml
- externalsecret.yaml"

# Add ingress if exposure is required
if [[ "$EXPOSE" != "none" ]]; then
  KUSTOMIZE_RESOURCES="${KUSTOMIZE_RESOURCES}
- ingress.yaml"
fi

cat > "${BASE_DIR}/base/kustomization.yaml" << EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
${KUSTOMIZE_RESOURCES}
EOF

# =============================================================================
# Ingress (conditional on exposure type)
# =============================================================================
if [[ "$EXPOSE" == "external" ]]; then
  cat > "${BASE_DIR}/base/ingress.yaml" << EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${SERVICE_NAME}-ingress
  namespace: ${NAMESPACE}
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS":443}]'
    # TODO: Replace with actual ACM certificate ARN
    alb.ingress.kubernetes.io/certificate-arn: PLACEHOLDER_CERT_ARN
    alb.ingress.kubernetes.io/ssl-redirect: "443"
spec:
  rules:
  - host: PLACEHOLDER_HOSTNAME
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: ${SERVICE_NAME}
            port:
              number: 80
EOF
  echo "  ✓ Created EXTERNAL ingress (internet-facing ALB)"

elif [[ "$EXPOSE" == "internal" ]]; then
  cat > "${BASE_DIR}/base/ingress.yaml" << EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${SERVICE_NAME}-ingress
  namespace: ${NAMESPACE}
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internal
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS":443}]'
    # TODO: Replace with actual ACM certificate ARN
    alb.ingress.kubernetes.io/certificate-arn: PLACEHOLDER_CERT_ARN
    alb.ingress.kubernetes.io/internal: "true"
spec:
  rules:
  - host: PLACEHOLDER_INTERNAL_HOSTNAME
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: ${SERVICE_NAME}
            port:
              number: 80
EOF
  echo "  ✓ Created INTERNAL ingress (VPC-only ALB)"
else
  echo "  · No ingress created (cluster-internal service only)"
fi

# =============================================================================
# Dev overlay
# =============================================================================
cat > "${BASE_DIR}/overlays/dev/kustomization.yaml" << EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

bases:
- ../../base

patches:
- path: deployment-patch.yaml
  target:
    kind: Deployment
    name: ${SERVICE_NAME}
EOF

cat > "${BASE_DIR}/overlays/dev/deployment-patch.yaml" << EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${SERVICE_NAME}
spec:
  replicas: 1
  template:
    spec:
      containers:
      - name: ${SERVICE_NAME}
        resources:
          requests:
            cpu: "100m"
            memory: "128Mi"
          limits:
            cpu: "500m"
            memory: "256Mi"
EOF

# =============================================================================
# Staging overlay (same as base, but no patch needed — inherits base replicas)
# =============================================================================
cat > "${BASE_DIR}/overlays/staging/kustomization.yaml" << EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

bases:
- ../../base
EOF

# =============================================================================
# Prod overlay (higher replicas, stricter resources)
# =============================================================================
cat > "${BASE_DIR}/overlays/prod/kustomization.yaml" << EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

bases:
- ../../base

patches:
- path: deployment-patch.yaml
  target:
    kind: Deployment
    name: ${SERVICE_NAME}
EOF

cat > "${BASE_DIR}/overlays/prod/deployment-patch.yaml" << EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${SERVICE_NAME}
spec:
  replicas: 3
  template:
    spec:
      containers:
      - name: ${SERVICE_NAME}
        resources:
          requests:
            cpu: "500m"
            memory: "512Mi"
          limits:
            cpu: "2000m"
            memory: "1Gi"
EOF

echo ""
echo "==================================================="
echo "  Scaffold complete!"
echo ""
echo "  Files created under: ${BASE_DIR}/"
echo ""
echo "  Next steps:"
echo "  1. Replace all PLACEHOLDER_ values in the manifests"
echo "  2. Add actual secret keys to base/externalsecret.yaml"
echo "  3. Update IRSA role ARN in base/serviceaccount.yaml"
echo "  4. Add ConfigMap values in base/configmap.yaml"
if [[ "$EXPOSE" != "none" ]]; then
  echo "  5. Update ALB cert ARN and hostname in base/ingress.yaml"
fi
echo ""
echo "  Deploy to dev:"
echo "  kubectl apply -k ${BASE_DIR}/overlays/dev"
echo "==================================================="
