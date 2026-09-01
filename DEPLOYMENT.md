# Deployment Documentation

## Overview

This document describes the CI/CD pipeline, deployment strategy, and operational procedures for the Candidate API service.

## Architecture

### Deployment Environments

- **Development (dev)**: Primary development environment with 2 replicas, liveness and readiness probes configured
- **Test**: Test environment with 3 replicas for validating releases before production
- **Production**: To be deployed following same patterns as test

### Deployment Strategy: Blue-Green with Automatic Promotion

The pipeline implements a **blue-green deployment strategy** with automatic promotion:

1. **Pull Request**: When a PR is opened or updated, a build and test workflow runs
   - Restores dependencies
   - Builds the solution
   - Runs unit tests
   - No deployment occurs

2. **Merge to Main**: When changes are merged to `main`, the full deployment pipeline triggers:
   - Build and test the solution
   - Create NuGet package for `CandidateApi.Contracts`
   - Build Docker image (multi-stage build for efficiency)
   - Scan Docker image for vulnerabilities using Trivy
   - Push image to GitHub Container Registry (GHCR)
   - Deploy to **Development** environment (blue slot)
   - Run smoke tests on dev
   - If dev passes, automatically promote to **Test** environment (blue slot)
   - Run smoke tests on test

### Blue-Green Deployment Details

**Initial State**: Blue slot receives traffic via Service selector

**Deployment Process**:
1. Green slot deployment is created with new image
2. Green pods start, readiness probes validate health
3. Service selector remains pointing to blue
4. Green deployment is tested independently
5. On validation, service selector switches to green
6. Blue deployment can remain for quick rollback

**Benefits**:
- Zero-downtime deployments
- Quick rollback by switching selector back to blue
- Easy validation before traffic cutover
- Full old environment remains available

**Switching Traffic (Manual Operation)**:
```bash
# View current traffic slot
kubectl get svc candidate-api -n candidate-api-dev -o jsonpath='{.spec.selector.slot}'

# Switch to green
kubectl patch svc candidate-api -n candidate-api-dev -p '{"spec":{"selector":{"slot":"green"}}}'

# Switch back to blue (rollback)
kubectl patch svc candidate-api -n candidate-api-dev -p '{"spec":{"selector":{"slot":"blue"}}}'
```

## GitHub Actions Workflows

### 1. PR Build Workflow (`.github/workflows/pr-build.yml`)

**Trigger**: Pull request opened or updated on any branch targeting `main`

**Steps**:
1. Checkout code
2. Setup .NET 10 (cached)
3. Restore dependencies
4. Build solution
5. Run unit tests
6. Upload test results as artifacts
7. Publish test results to PR

**Artifacts**: Test results (TRX format)

### 2. Build & Deploy Workflow (`.github/workflows/deploy.yml`)

**Trigger**: Push to `main` branch

**Jobs** (Sequential):

#### Job 1: Build
- Builds .NET solution
- Runs unit tests
- Creates NuGet package from `CandidateApi.Contracts`
- Builds Docker image with multi-stage approach
- Scans image for vulnerabilities (Trivy)
- Pushes image to GHCR with tags:
  - `main-{sha}`
  - `main` (branch tag)
  - Semantic version tags if applicable

**Artifacts**: NuGet package

#### Job 2: Deploy to Dev
- Requires: Build job to complete
- Environment: `development`
- Deploys to dev Kubernetes namespace
- Runs smoke tests against `/health/live` and `/health/ready` endpoints

#### Job 3: Promote to Test
- Requires: Build and Deploy to Dev jobs to complete
- Only runs if dev deployment and tests pass
- Environment: `test`
- Deploys same image to test Kubernetes namespace
- Runs smoke tests on test environment

## Kubernetes Manifests

### Namespace Structure

```
candidate-api-dev/
  ├── ServiceAccount
  ├── Role & RoleBinding
  ├── ConfigMap (appsettings)
  ├── Deployment (blue slot)
  ├── Deployment (green slot, for blue-green strategy)
  ├── Service (ClusterIP)
  ├── HorizontalPodAutoscaler
  ├── PodDisruptionBudget
  └── NetworkPolicies

candidate-api-test/
  └── (Similar structure)
```

### Key Kubernetes Features

#### Security Context
- Runs as non-root user (UID 1000)
- Read-only root filesystem (logs volume is writable)
- No privilege escalation
- Dropped all Linux capabilities

#### Health Checks
- **Liveness Probe**: `/health/live` - indicates if pod should be restarted
  - Initial delay: 10s
  - Period: 10s
  - Timeout: 3s
  - Failure threshold: 3
  
- **Readiness Probe**: `/health/ready` - indicates if pod should receive traffic
  - Initial delay: 5s
  - Period: 5s
  - Timeout: 3s
  - Failure threshold: 2 (stricter than liveness)
  
- **Startup Probe**: Allows graceful startup of app
  - Period: 5s
  - Max attempts: 30 (~150 seconds for startup)

#### Resource Management
- **Requests**: 100m CPU, 256Mi memory
- **Limits**: 500m CPU, 512Mi memory
- Allows proper scheduling and prevents resource starvation

#### Horizontal Pod Autoscaler (HPA)
- Scales based on CPU (70%) and memory (80%) utilization
- Dev: 2-5 replicas
- Test: 3-8 replicas
- Graceful scale-down: waits 300s before scaling down

#### Pod Disruption Budget (PDB)
- Dev: Maintains minimum 1 pod available
- Test: Maintains minimum 2 pods available
- Prevents disruptions during cluster maintenance

#### Network Policies
- **Ingress**: Only from ingress-nginx namespace on port 8080
- **Egress**: 
  - DNS (port 53 TCP/UDP)
  - Database (port 5432)
  - Cache/Redis (port 6379)
- Default deny-all policy for security

#### Pod Affinity
- Prefers to spread pods across different nodes
- Improves resilience to node failures

## Docker Image

### Multi-stage Build
1. **Builder Stage**: 
   - Uses `mcr.microsoft.com/dotnet/sdk:10.0`
   - Restores NuGet packages
   - Builds solution in Release mode
   - Runs unit tests
   - Publishes API
   - Packages contracts library as NuGet

2. **Runtime Stage**:
   - Uses `mcr.microsoft.com/dotnet/aspnet:10.0` (slimmer)
   - Creates non-root user (1000)
   - Copies published app
   - Configures read-only filesystem
   - Sets health check
   - Exposes port 8080

### Security Features
- Non-root user execution
- Health check configured
- Minimal attack surface (runtime-only image)
- No development tools in final image

## Local Development

### Run API Locally
```bash
cd /Users/josh/Desktop/sre-cot/sre-take-home
dotnet restore
dotnet build SreTakeHome.sln
dotnet run --project src/CandidateApi/CandidateApi.csproj --urls http://localhost:5000
```

### Test API
```bash
# Service metadata
curl http://localhost:5000/

# Liveness check
curl http://localhost:5000/health/live

# Readiness check (depends on dependencies being healthy)
curl http://localhost:5000/health/ready

# Work items
curl http://localhost:5000/api/work-items
```

### Run Unit Tests
```bash
dotnet test SreTakeHome.sln
```

## Deployment to Kubernetes

### Prerequisites
- Access to Kubernetes cluster
- `kubectl` configured to target cluster
- Container registry credentials configured (for GHCR)

### Manual Deployment to Dev
```bash
# Set current context
kubectl config use-context <dev-cluster-context>

# Deploy manifests
kubectl apply -f k8s/dev/

# Wait for deployment
kubectl rollout status deployment/candidate-api-blue -n candidate-api-dev

# Port-forward for testing
kubectl port-forward -n candidate-api-dev svc/candidate-api 8080:80

# Test endpoints
curl http://localhost:8080/health/live
curl http://localhost:8080/health/ready
```

### Manual Deployment to Test
```bash
# Set context for test cluster
kubectl config use-context <test-cluster-context>

# Deploy manifests
kubectl apply -f k8s/test/

# Wait for deployment
kubectl rollout status deployment/candidate-api-blue -n candidate-api-test
```

### Blue-Green Deployment Process
```bash
# 1. Deploy new version to green slot
kubectl apply -f k8s/dev/deployment-green.yaml

# 2. Wait for green pods to be ready
kubectl wait --for=condition=available --timeout=600s deployment/candidate-api-green -n candidate-api-dev

# 3. Test green deployment
kubectl port-forward -n candidate-api-dev svc/candidate-api 8080:80 &
curl http://localhost:8080/health/ready

# 4. Switch traffic from blue to green
kubectl patch svc candidate-api -n candidate-api-dev -p '{"spec":{"selector":{"slot":"green"}}}'

# 5. Monitor for issues
kubectl logs -f -l app=candidate-api,slot=green -n candidate-api-dev

# 6. If all good, delete blue and rename green to blue
kubectl delete deployment candidate-api-blue -n candidate-api-dev
kubectl patch deployment candidate-api-green -n candidate-api-dev -p '{"metadata":{"labels":{"version":"blue","slot":"blue"}}}'

# Or rollback if issues detected
kubectl patch svc candidate-api -n candidate-api-dev -p '{"spec":{"selector":{"slot":"blue"}}}'
```

## Monitoring & Observability

### Health Endpoints
- `/health/live`: Used by Kubernetes liveness probe
- `/health/ready`: Used by Kubernetes readiness probe and application load balancers
- `/health/ready` returns 503 when dependencies are unhealthy

### Readiness Evaluation
The API evaluates configured dependencies in `appsettings.json`:
- Database (PostgreSQL)
- Cache (Redis)
- Third-party HTTP services (Billing service)

Dependencies can be marked unhealthy by updating configuration:
```json
{
  "Dependencies": [
    {
      "Name": "postgres",
      "Type": "database",
      "Healthy": false  // This will cause readiness check to fail
    }
  ]
}
```

### Prometheus Metrics
Pod annotations enable Prometheus scraping:
```yaml
prometheus.io/scrape: "true"
prometheus.io/port: "8080"
prometheus.io/path: "/metrics"
```

### Recommended Monitoring Setup
For full observability, integrate with:
- **Prometheus**: Metric collection
- **Grafana**: Visualization
- **Loki**: Log aggregation
- **Alertmanager**: Alert routing

## Security Considerations

### Image Security
- ✅ Multi-stage build minimizes final image size and attack surface
- ✅ Trivy vulnerability scanning in CI/CD pipeline
- ✅ Non-root user execution
- ✅ Read-only filesystem
- ✅ No elevated capabilities

### Kubernetes Security
- ✅ Security contexts enforce non-root, read-only where possible
- ✅ Network policies restrict traffic to/from pods
- ✅ RBAC with minimal permissions (read-only ConfigMaps/Secrets)
- ✅ Resource limits prevent resource exhaustion attacks

### Secrets Management
- **Current**: ConfigMaps used for non-sensitive config
- **Recommended**: 
  - Use Kubernetes Secrets for sensitive data (database credentials, API keys)
  - Integrate with external secret manager (HashiCorp Vault, Azure Key Vault)
  - Encrypt secrets at rest in etcd
  - Use pod service account for workload identity

### Container Registry
- GHCR (GitHub Container Registry) stores images
- Authenticated push via GitHub Actions (uses `GITHUB_TOKEN`)
- Recommend: Enable Dependabot for base image updates

## Incident Response

### Service Unresponsive
1. Check pod status: `kubectl get pods -n candidate-api-dev`
2. Check logs: `kubectl logs -f <pod-name> -n candidate-api-dev`
3. Check readiness: `kubectl describe pod <pod-name> -n candidate-api-dev`
4. Check events: `kubectl get events -n candidate-api-dev`

### Readiness Check Failing
1. Identify which dependency is unhealthy (check response from `/health/ready`)
2. Verify dependency connectivity from pod
3. Update configuration to mark dependency healthy when recovered
4. Pod will automatically rejoin load balancing

### Failed Deployment
1. Check if new image exists: `docker pull ghcr.io/your-org/candidate-api:main-<sha>`
2. Check rollout status: `kubectl rollout status deployment/candidate-api-blue -n candidate-api-dev`
3. View deployment events: `kubectl describe deployment candidate-api-blue -n candidate-api-dev`
4. Rollback: `kubectl rollout undo deployment/candidate-api-blue -n candidate-api-dev`

### Quick Rollback to Previous Version
```bash
# View rollout history
kubectl rollout history deployment/candidate-api-blue -n candidate-api-dev

# Rollback to previous revision
kubectl rollout undo deployment/candidate-api-blue -n candidate-api-dev

# Or rollback to specific revision
kubectl rollout undo deployment/candidate-api-blue -n candidate-api-dev --to-revision=2
```

## Assumptions & Limitations

### Current Assumptions
1. **Kubernetes Cluster**: Assumes access to Kubernetes cluster (can mock for demo)
2. **Container Registry**: Uses GHCR (requires GitHub authentication)
3. **No External Dependencies**: For demo, Postgres/Redis/Billing are marked as healthy
4. **Single Region**: Currently configured for single region deployment
5. **No Persistence**: Using in-memory storage (suitable for stateless API)
6. **Manual Environment Promotion**: Dev→Test is automatic in workflow, but production requires manual approval

### Limitations & Future Improvements

#### Security & Secrets
- [ ] Integrate with Vault or Azure Key Vault for secrets management
- [ ] Add pod identity/workload identity for cloud provider integration
- [ ] Implement RBAC for different teams/environments
- [ ] Add image signing and verification

#### Deployment
- [ ] Implement Canary deployment strategy with automated rollback on error rates
- [ ] Add approval gates for production promotion
- [ ] Implement GitOps with ArgoCD for declarative deployments
- [ ] Add comprehensive pre-deployment validation

#### Observability
- [ ] Add distributed tracing (Jaeger/Tempo)
- [ ] Implement custom application metrics
- [ ] Add SLO/SLI definitions with error budgets
- [ ] Create dashboards and alerts in Grafana

#### Testing
- [ ] Add integration tests with mocked dependencies
- [ ] Add end-to-end smoke tests after deployment
- [ ] Add load testing to validate autoscaling
- [ ] Add security scanning (SAST, dependency scanning)

#### Infrastructure
- [ ] Define infrastructure as code (Terraform, Pulumi, or Bicep)
- [ ] Implement multi-region deployment
- [ ] Add disaster recovery procedures
- [ ] Implement backup and restore procedures

#### Documentation
- [ ] Add runbooks for common operations
- [ ] Add troubleshooting guide
- [ ] Add cost optimization recommendations
- [ ] Add performance tuning guide

## Related Files

- GitHub Actions workflows: [`.github/workflows/`](.github/workflows/)
- Kubernetes manifests: 
  - Dev: [`k8s/dev/`](k8s/dev/)
  - Test: [`k8s/test/`](k8s/test/)
- Dockerfile: [`Dockerfile`](Dockerfile)
- Application code: [`src/`](src/)
- Tests: [`tests/`](tests/)
