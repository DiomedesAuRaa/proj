# Incident Response Runbook

## Overview

This runbook covers common failure scenarios, diagnosis procedures, and remediation steps for the Candidate API service.

---

## Scenario 1: Readiness Check Failing (Dependency Unhealthy)

### Detection
- Pod shows "Not Ready" in `kubectl get pods` output
- Kubernetes doesn't route traffic to affected pod
- Service endpoints show reduced available pods
- Alerts fire on pod readiness failures

### Diagnosis Steps

**1. Check pod status:**
```bash
kubectl get pods -n candidate-api-dev -o wide
kubectl describe pod <pod-name> -n candidate-api-dev | grep -A 10 "Conditions"
```

**2. Check readiness probe failure details:**
```bash
kubectl logs <pod-name> -n candidate-api-dev --tail=50
```

**3. Query readiness endpoint directly:**
```bash
kubectl port-forward -n candidate-api-dev pod/<pod-name> 8080:8080
curl http://localhost:8080/health/ready | jq
```

**4. Identify which dependency is unhealthy:**
The `/health/ready` response looks like:
```json
{
  "Status": "Unhealthy",
  "Dependencies": [
    {
      "Name": "postgres",
      "Type": "database",
      "Status": "Unhealthy",
      "Message": "Connection timeout"
    },
    {
      "Name": "redis",
      "Type": "cache",
      "Status": "Healthy"
    }
  ]
}
```

### Root Cause Examples

| Dependency | Common Causes | Symptoms |
|-----------|---------------|----------|
| PostgreSQL | Connection pool exhausted, DB unavailable | "Connection timeout" |
| Redis | Memory full, eviction happening, network partition | "Failed to connect" |
| Billing Service | Downstream service down, network issues | "HTTP error 5xx" |

### Remediation

**Option A: Fix the dependency (preferred)**
1. Investigate the failing dependency
2. Resolve the underlying issue (e.g., restart DB, increase memory)
3. Pod will automatically become ready once dependency recovers

**Option B: Mark dependency as healthy temporarily (emergency)**
1. If dependency will be down for extended period, mark as healthy:
```bash
kubectl set env deployment/candidate-api-blue \
  -n candidate-api-dev \
  CANDIDATE_API_DEPENDENCIES_0_HEALTHY=true
```

2. Update ConfigMap to mark as healthy:
```bash
kubectl patch configmap candidate-api-config -n candidate-api-dev \
  --type merge -p '{"data":{"appsettings.json":"{...\"Healthy\":true...}"}}'
```

3. Restart pods to pick up new config:
```bash
kubectl rollout restart deployment/candidate-api-blue -n candidate-api-dev
```

4. Verify pods are ready:
```bash
kubectl rollout status deployment/candidate-api-blue -n candidate-api-dev
```

### Prevention
- Add monitoring/alerting on dependencies (is Postgres/Redis/Billing healthy?)
- Set up circuit breakers in application code
- Document expected response times and timeout values
- Add external dependency health checks to CI/CD

---

## Scenario 2: Deployment Fails or Rollout Hangs

### Detection
- `kubectl rollout status` reports: "waiting for rollout"
- Pods stuck in "ImagePullBackOff" or "CrashLoopBackOff"
- No ready replicas available
- Service experiences downtime

### Diagnosis Steps

**1. Check deployment status:**
```bash
kubectl describe deployment candidate-api-blue -n candidate-api-dev
kubectl get events -n candidate-api-dev --sort-by='.lastTimestamp'
```

**2. Check pod status and logs:**
```bash
kubectl get pods -n candidate-api-dev -o wide
kubectl logs -f <pod-name> -n candidate-api-dev
kubectl describe pod <pod-name> -n candidate-api-dev
```

**3. Identify issue type:**

| Status | Likely Cause |
|--------|------------|
| ImagePullBackOff | Image doesn't exist, auth failed, wrong tag |
| CrashLoopBackOff | App crashed, bad configuration, missing dependencies |
| Pending | Insufficient resources, node issues |
| CreateContainerConfigError | Bad ConfigMap/Secret, volume issues |

### Remediation

**For ImagePullBackOff:**
```bash
# Verify image exists
docker pull ghcr.io/your-org/candidate-api:main-<sha>

# Check image pull secrets (if using private registry)
kubectl get secrets -n candidate-api-dev
kubectl describe secret <secret-name> -n candidate-api-dev

# Re-push image if missing
git push origin main  # Triggers GitHub Actions build
```

**For CrashLoopBackOff:**
```bash
# Check application logs
kubectl logs <pod-name> -n candidate-api-dev

# Common issues:
# - Configuration missing: verify ConfigMap exists
# - Port already in use: check if service port conflicts
# - Dependencies unavailable: check health/ready endpoint

# Fix and redeploy
kubectl delete pod <pod-name> -n candidate-api-dev  # Force restart
kubectl wait --for=condition=ready pod/<pod-name> -n candidate-api-dev --timeout=120s
```

**For Insufficient Resources:**
```bash
# Check node capacity
kubectl top nodes
kubectl describe nodes

# Check pod resource requests
kubectl describe deployment candidate-api-blue -n candidate-api-dev | grep -A 5 "Requests"

# Scale down deployment temporarily to free resources
kubectl scale deployment candidate-api-blue -n candidate-api-dev --replicas=1

# Or delete other non-critical workloads
# Then re-scale back up
kubectl scale deployment candidate-api-blue -n candidate-api-dev --replicas=2
```

### Immediate Mitigation: Rollback to Previous Version

**Option 1: Rollback using Kubernetes rollout**
```bash
# View rollout history
kubectl rollout history deployment/candidate-api-blue -n candidate-api-dev

# Rollback to previous revision
kubectl rollout undo deployment/candidate-api-blue -n candidate-api-dev

# Verify rollback
kubectl rollout status deployment/candidate-api-blue -n candidate-api-dev
```

**Option 2: Blue-Green rollback (if using green deployment)**
```bash
# If new version is in green slot
kubectl patch svc candidate-api -n candidate-api-dev -p '{"spec":{"selector":{"slot":"blue"}}}'
```

**Option 3: Redeploy from known-good commit**
```bash
# Get git commit of last working deployment
git log --oneline | head -5

# Check out previous commit
git checkout <commit-sha>

# This triggers GitHub Actions to rebuild and deploy
git push origin HEAD:main
```

### Prevention
- Add deployment validation in CI pipeline
- Test deployments against staging environment first
- Set readiness/liveness probe thresholds conservatively
- Monitor rollout in real-time using Slack alerts

---

## Scenario 3: All Pods Unhealthy (Complete Service Outage)

### Detection
- All pods showing "Not Ready"
- Service has zero available endpoints
- User-facing requests returning 503 or connection refused
- Alert: "Service unavailable" or "All pods unhealthy"

### Immediate Actions (First 2 Minutes)

**1. Determine scope:**
```bash
# Check all namespaces
kubectl get pods -A -l app=candidate-api

# Check which environment(s) affected
kubectl get pods -n candidate-api-dev
kubectl get pods -n candidate-api-test
```

**2. Quick status check:**
```bash
# Check recent deployment
kubectl rollout history deployment/candidate-api-blue -n candidate-api-dev

# Check recent events
kubectl get events -n candidate-api-dev --sort-by='.lastTimestamp' | tail -20
```

**3. Determine if recent deployment caused it:**
```bash
# Check deployment timestamp
kubectl get deployment candidate-api-blue -n candidate-api-dev -o jsonpath='{.metadata.creationTimestamp}'

# If recent, consider rollback immediately
kubectl rollout undo deployment/candidate-api-blue -n candidate-api-dev
```

### Diagnosis Steps (Parallel Investigation)

**Thread 1: Application Issues**
```bash
kubectl logs -f $(kubectl get pods -n candidate-api-dev -o jsonpath='{.items[0].metadata.name}') -n candidate-api-dev
# Look for panic, segfault, or repeated errors
```

**Thread 2: Dependency Issues**
```bash
# Check if postgres/redis/billing are accessible from pod
kubectl exec -it <pod-name> -n candidate-api-dev -- bash
ping postgres
ping redis
curl https://billing-api.example.com/health
```

**Thread 3: Kubernetes Issues**
```bash
# Check cluster health
kubectl get nodes
kubectl top nodes
kubectl describe nodes

# Check if there are node issues or resource exhaustion
```

**Thread 4: Configuration Issues**
```bash
# Verify ConfigMap exists
kubectl get configmap candidate-api-config -n candidate-api-dev

# Check if values are correct
kubectl get configmap candidate-api-config -n candidate-api-dev -o yaml
```

### Remediation

**Most Common Cause: Recent Bad Deployment**
```bash
kubectl rollout undo deployment/candidate-api-blue -n candidate-api-dev
kubectl rollout status deployment/candidate-api-blue -n candidate-api-dev
sleep 10
curl http://$(kubectl get svc -n candidate-api-dev candidate-api -o jsonpath='{.spec.clusterIP}'):80/health/live
```

**If Rollback Fails: Bypass Probes Temporarily**
```bash
# Edit deployment to disable readiness probe
kubectl patch deployment candidate-api-blue -n candidate-api-dev --type json -p '[{"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe","value":null}]'

# This allows pods to be marked ready even if checks fail
# Once you identify the issue, re-enable probes:
kubectl rollout restart deployment/candidate-api-blue -n candidate-api-dev
```

**If All Else Fails: Emergency Scale to 0 and Redeploy**
```bash
# Stop accepting traffic (scale to 0)
kubectl scale deployment candidate-api-blue -n candidate-api-dev --replicas=0

# Wait for investigation/fix in parallel
# Then redeploy from known-good version
git checkout main~1  # or specific good commit
git push origin HEAD:main
```

### Communication
1. **Alert stakeholders** - "Service experiencing degraded performance"
2. **Open incident in on-call system**
3. **Post updates** - Every 5-10 minutes during incident
4. **Post-mortem** - After service recovered (within 24 hours)

---

## Scenario 4: Memory/CPU Leak (Gradual Performance Degradation)

### Detection
- Pods getting killed with OOMKilled status
- Gradual increase in response times
- Error rate increasing over time (hours/days)
- Kubernetes evicting pods due to memory pressure

### Diagnosis Steps

**1. Check resource usage trends:**
```bash
# Current usage
kubectl top pods -n candidate-api-dev

# Watch over time
kubectl top pods -n candidate-api-dev --containers
watch -n 5 'kubectl top pods -n candidate-api-dev'
```

**2. Check for OOMKilled pods:**
```bash
kubectl get pods -n candidate-api-dev -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[0].lastState.terminated.reason}{"\n"}{end}'
```

**3. Analyze application logs:**
```bash
# Get logs for pod that was OOMKilled
kubectl logs <pod-name> -n candidate-api-dev --previous

# Look for patterns: large allocations, loops, cache growth
```

**4. Check if it's application code or dependency:**
```bash
# Monitor pod memory over time
kubectl port-forward -n candidate-api-dev pod/<pod-name> 8080:8080 &
curl http://localhost:8080/metrics | grep memory

# Or check with exec
kubectl exec -it <pod-name> -n candidate-api-dev -- ps aux
```

### Remediation

**Option A: Increase Memory Limits (Quick Fix)**
```bash
kubectl set resources deployment/candidate-api-blue -n candidate-api-dev \
  --limits=memory=1Gi,cpu=1000m \
  --requests=memory=512Mi,cpu=250m

kubectl rollout status deployment/candidate-api-blue -n candidate-api-dev
```

**Option B: Add Memory Monitoring Alert**
```yaml
# Add to monitoring/alerting:
- If memory > 80% of limit for 5 minutes
- If memory growing > 50MB/minute
- Alert on next OOMKill attempt
```

**Option C: Investigate and Fix Root Cause**
```bash
# Common causes:
# 1. Unbounded cache - add TTL or size limit
# 2. Connection pool leak - check for open connections
# 3. Large allocations in loop - optimize algorithm
# 4. Dependency memory issue - check if Postgres/Redis is leaking

# Fix in code, commit, and redeploy
git commit -am "Fix memory leak in cache manager"
git push origin main  # Triggers rebuild and deploy
```

### Prevention
- Add memory limit alerts (85%, 95% of limit)
- Add memory growth rate monitoring
- Add code reviews focused on memory allocation
- Use dotMemory or similar profiler in staging environment

---

## Scenario 5: Pod Deployment Blocked by Pod Disruption Budget (PDB)

### Detection
- Node drain/upgrade is blocked
- Manual pod deletion fails with "Forbidden"
- Error: "Cannot evict pod as it would violate PodDisruptionBudget"

### Example Error
```
Error from server (Forbidden): Cannot evict pod as it would violate disruption budget for candidate-api
```

### Remediation

**Option A: Temporarily Increase Replicas**
```bash
# Scale up to maintain minimum available during disruption
kubectl scale deployment candidate-api-blue -n candidate-api-dev --replicas=3

# Now node drain can proceed (1 pod can be disrupted)
# After disruption completes, scale back down
kubectl scale deployment candidate-api-blue -n candidate-api-dev --replicas=2
```

**Option B: Modify or Temporarily Remove PDB**
```bash
# Remove PDB temporarily
kubectl delete pdb candidate-api -n candidate-api-dev

# Perform maintenance

# Re-apply PDB
kubectl apply -f k8s/dev/deployment.yaml
```

**Option C: Modify PDB to Be More Lenient**
```bash
# Change minAvailable to 0 temporarily
kubectl patch pdb candidate-api -n candidate-api-dev -p '{"spec":{"minAvailable":0}}'

# Perform maintenance

# Restore PDB
kubectl patch pdb candidate-api -n candidate-api-dev -p '{"spec":{"minAvailable":1}}'
```

---

## Scenario 6: Image Scan Fails (Trivy Vulnerability Found)

### Detection
- GitHub Actions workflow fails at "Run Trivy vulnerability scan" step
- SARIF results uploaded to GitHub Security tab
- Deployment does not proceed to dev/test

### Common Vulnerabilities

| Type | Severity | Action |
|------|----------|--------|
| Base image has CVE | HIGH/CRITICAL | Update base image version |
| NuGet dependency vulnerability | MEDIUM | Update package version |
| Linux package vulnerability | HIGH | Update base image |

### Remediation

**Step 1: Review the vulnerability**
```bash
# In GitHub UI: Security tab → Code scanning → Trivy results
# Look at:
# - Package name and version
# - CVE number
# - CVSS score
# - Is it exploitable in this context?
```

**Step 2: Fix if exploitable**

**For Base Image Issues:**
```dockerfile
# Update Dockerfile
FROM mcr.microsoft.com/dotnet/sdk:10.0.x  # Change version
```

**For NuGet Package Issues:**
```bash
# Update package version
# Edit src/CandidateApi/CandidateApi.csproj
# Update <PackageReference Version="x.y.z" />
```

**Step 3: Rebuild and re-scan**
```bash
git commit -am "Fix CVE-XXX by updating package to X.Y.Z"
git push origin main  # Triggers rebuild and scan
```

**Step 4: If Fix Not Available (Rare)**
```bash
# Add exception to workflow (NOT RECOMMENDED)
# OR suppress in Trivy config
# OR document as accepted risk

# Escalate to security team for approval
```

### Prevention
- Enable Dependabot to automatically create PRs for updates
- Add security scanning to PR builds
- Monitor CVE feeds for used packages
- Have regular vulnerability management schedule

---

## Response Playbook Summary

### For Each Incident:

1. **Detect** - Alert fires
2. **Assess** - Severity, scope, business impact (2 min)
3. **Mitigate** - Take immediate action to reduce impact (2-5 min)
4. **Diagnose** - Find root cause while service is stabilized (5-30 min)
5. **Resolve** - Fix underlying issue (5-60 min)
6. **Verify** - Confirm service is healthy (2-5 min)
7. **Communicate** - Update stakeholders (ongoing)
8. **Document** - Post-mortem and lessons learned (24 hours)

### Escalation Path

```
L1: Pod unhealthy
  ↓ (15 min no resolution)
L2: Service unavailable in one environment
  ↓ (5 min no resolution)
L3: Service unavailable in all environments
  ↓ (immediately)
Incident Commander + On-call engineer
```

### On-Call Duties

- Monitor alerts
- Follow this runbook
- Communicate status every 10 minutes
- Escalate after 15 minutes without progress
- Document actions and findings

---

## Additional Resources

- Kubernetes Troubleshooting: https://kubernetes.io/docs/tasks/debug-application-cluster/
- .NET Diagnostics: https://github.com/dotnet/diagnostics
- Container Debugging: https://www.docker.com/blog/how-to-debug-containers/
- Health Check Best Practices: https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/
