# Security, Secrets Management & CI/CD Maturity

## Overview

This document describes security measures, secrets management strategies, and CI/CD pipeline maturity features implemented for the Candidate API service.

---

## 1. Security Scanning in CI/CD Pipeline

### 1.1 Container Image Vulnerability Scanning

**Tool**: Trivy (Aqua Security)

**Integration**: GitHub Actions workflow (`.github/workflows/deploy.yml`)

```yaml
- name: Run Trivy vulnerability scan
  uses: aquasecurity/trivy-action@master
  with:
    image-ref: ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}:${{ github.sha }}
    format: 'sarif'
    output: 'trivy-results.sarif'
    severity: 'CRITICAL,HIGH'

- name: Upload Trivy results
  uses: github/codeql-action/upload-sarif@v2
  with:
    sarif_file: 'trivy-results.sarif'
```

**What It Scans**:
- Base image vulnerabilities (OS packages)
- Application dependencies (.NET assemblies)
- Known CVEs with CVSS scoring

**Severity Levels**:
- CRITICAL: Immediate action required, blocks deployment
- HIGH: Should be resolved before production
- MEDIUM: Monitor, plan for update
- LOW: Informational

**How It Blocks Deployment**:
The workflow is configured to scan CRITICAL and HIGH severity issues. If found:
1. Workflow continues (doesn't hard-fail yet)
2. Results are uploaded to GitHub Security → Code scanning
3. Developer must review and approve
4. Recommendation: Add approval gate before production promotion

**Remediation Process**:
```bash
# 1. Identify vulnerability
# 2. Check severity and exploitability in your context
# 3. Update base image or dependency
docker pull mcr.microsoft.com/dotnet/aspnet:10.0.x  # Update minor version

# 4. Rebuild and test
git commit -am "Update base image to address CVEs"
git push origin main

# 5. Verify scan passes
# 6. Deploy
```

### 1.2 Dependency Vulnerability Scanning

**Recommended Tools**:
- GitHub Dependabot: Automatic dependency updates
- OWASP Dependency-Check: Manual scanning
- NuGet Audit: .NET specific

**To Add Dependabot** (GitHub will auto-enable):
1. Navigate to Settings → Code security and analysis
2. Enable "Dependabot alerts"
3. Enable "Dependabot security updates"
4. Dependabot will automatically create PRs for updates

**Example Dependabot Configuration** (`.github/dependabot.yml`):
```yaml
version: 2
updates:
  - package-ecosystem: "nuget"
    directory: "/"
    schedule:
      interval: "weekly"
      day: "monday"
      time: "04:00"
    reviewers:
      - "platform-team"
    labels:
      - "dependencies"
      - "nuget"
    commit-message:
      prefix: "chore:"
```

### 1.3 Static Code Analysis (SAST)

**Recommended for .NET**:
- CodeQL: GitHub's static analysis engine
- SonarQube: Comprehensive code quality scanning
- Roslyn analyzers: Built-in .NET analyzers

**CodeQL Setup** (`.github/workflows/codeql-analysis.yml`):
```yaml
name: CodeQL

on:
  push:
    branches: [ main ]
  pull_request:
    branches: [ main ]

jobs:
  analyze:
    runs-on: ubuntu-latest
    
    strategy:
      fail-fast: false
      matrix:
        language: [ 'csharp' ]
    
    steps:
      - uses: actions/checkout@v4
      
      - uses: github/codeql-action/init@v2
        with:
          languages: ${{ matrix.language }}
      
      - uses: github/codeql-action/autobuild@v2
      
      - uses: github/codeql-action/analyze@v2
```

**Built-in .NET Analyzers**:
```xml
<!-- In CandidateApi.csproj -->
<PropertyGroup>
  <EnforceCodeStyleInBuild>true</EnforceCodeStyleInBuild>
  <EnableNETAnalyzers>true</EnableNETAnalyzers>
  <AnalysisLevel>latest</AnalysisLevel>
  <TreatWarningsAsErrors>true</TreatWarningsAsErrors>
</PropertyGroup>
```

---

## 2. Secrets Management

### 2.1 Current State: GitHub Secrets

**For CI/CD Pipeline Secrets**:
- Use GitHub Secrets for API keys, credentials
- Accessed via `${{ secrets.SECRET_NAME }}`
- Never print to logs

**Example in Workflow**:
```yaml
- name: Docker login
  uses: docker/login-action@v3
  with:
    registry: ${{ env.REGISTRY }}
    username: ${{ github.actor }}
    password: ${{ secrets.GITHUB_TOKEN }}  # Automatic for GHCR
```

**How to Add New Secret**:
1. Go to GitHub Repo → Settings → Secrets and variables → Actions
2. Click "New repository secret"
3. Add name (e.g., `NUGET_API_KEY`) and value
4. Use in workflow: `${{ secrets.NUGET_API_KEY }}`

### 2.2 Recommended: External Secrets Management

For production, integrate with external secret manager:

**Option A: Azure Key Vault (if using Azure)**
```yaml
- name: Azure Login
  uses: azure/login@v1
  with:
    creds: ${{ secrets.AZURE_CREDENTIALS }}

- name: Get secrets from Key Vault
  uses: azure/get-keyvault-secrets@v1
  with:
    keyvault: "my-keyvault"
    secrets: "database-password,api-key"
  id: keyvault

- name: Use secret
  run: echo "Password=${{ steps.keyvault.outputs.database-password }}"
```

**Option B: HashiCorp Vault**
```yaml
- name: Get secrets from Vault
  uses: hashicorp/vault-action@v2
  with:
    url: ${{ secrets.VAULT_ADDR }}
    method: jwt
    path: jwt
    role: candidate-api
    jwtPayloadFormat: compact
    secrets: |
      secret/data/prod/database password | DB_PASSWORD;
      secret/data/prod/api-key key | API_KEY
```

**Option C: GitHub OIDC + Cloud Provider**
```yaml
permissions:
  contents: read
  id-token: write

- name: Assume AWS role
  uses: aws-actions/configure-aws-credentials@v2
  with:
    role-to-assume: arn:aws:iam::ACCOUNT:role/GithubActionsRole
    aws-region: us-east-1

- name: Get secrets from AWS Secrets Manager
  run: |
    aws secretsmanager get-secret-value --secret-id prod/db-password
```

### 2.3 Kubernetes Secrets Management

**Current**: ConfigMaps for non-sensitive config

**Recommended**: Kubernetes Secrets for sensitive data

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: candidate-api-secrets
  namespace: candidate-api-dev
type: Opaque
stringData:
  database-password: "{{ DATABASE_PASSWORD }}"
  api-key: "{{ API_KEY }}"
---
apiVersion: v1
kind: Deployment
metadata:
  name: candidate-api-blue
spec:
  template:
    spec:
      containers:
      - name: candidate-api
        env:
        - name: ConnectionStrings__Default
          valueFrom:
            secretKeyRef:
              name: candidate-api-secrets
              key: database-password
```

**Secret Injection in CI/CD**:
```bash
# Using envsubst or similar
export DATABASE_PASSWORD="secret123"
envsubst < k8s/dev/secrets.yaml | kubectl apply -f -

# Or use Sealed Secrets for GitOps
kubeseal -f k8s/dev/secrets.yaml -w k8s/dev/secrets-sealed.yaml
kubectl apply -f k8s/dev/secrets-sealed.yaml
```

**Best Practices**:
- ✅ Never commit secrets to git (use `.gitignore`)
- ✅ Encrypt secrets at rest in etcd
- ✅ Use RBAC to restrict secret access
- ✅ Rotate secrets regularly
- ✅ Audit secret access
- ✅ Use separate secrets per environment
- ❌ Don't print secrets in logs
- ❌ Don't use base64 as encryption (it's just encoding)

---

## 3. Environment-Specific Configuration

### 3.1 Configuration Management Strategy

**Development Environment**:
- Relaxed logging (Debug level)
- All dependencies marked healthy for testing
- Quick startup/shutdown
- Used for feature development

**Test Environment**:
- Production-like configuration
- Production logging level
- Real health checks
- Used for QA and validation

**Production** (Future):
- Strict security settings
- Minimal logging (errors only)
- Real health checks with actual dependencies
- Used for customer traffic

### 3.2 Configuration Hierarchy

1. **Base Configuration** (`appsettings.json`):
   - Shared defaults
   - Checked into git

2. **Environment Configuration** (`appsettings.{Environment}.json`):
   - Environment-specific overrides
   - Checked into git (no secrets)

3. **Runtime Configuration** (Environment Variables/ConfigMaps):
   - Secrets and sensitive data
   - Injected at deployment time
   - Never checked into git

### 3.3 Example: Database Connection String

**appsettings.json** (Base - Public):
```json
{
  "ConnectionStrings": {
    "Default": "Server=postgres;Database=candidate_api;"
  }
}
```

**Environment Variable** (Secret - Injected):
```bash
export ConnectionStrings__Default="Server=prod-postgres.cloud.azure.com;Database=candidate_api;User Id=admin;Password=SecureP@ssw0rd;"
```

**In Kubernetes Deployment**:
```yaml
containers:
- name: candidate-api
  env:
  - name: ConnectionStrings__Default
    valueFrom:
      secretKeyRef:
        name: candidate-api-secrets
        key: database-connection-string
```

---

## 4. Pipeline Optimizations

### 4.1 Build Caching

**Docker Layer Caching**:
```yaml
- name: Build and push Docker image
  uses: docker/build-push-action@v5
  with:
    context: .
    push: true
    cache-from: type=gha
    cache-to: type=gha,mode=max
```

**Benefits**:
- First build: Full build (~3-5 minutes)
- Subsequent builds: Use cached layers (~30 seconds)
- Only unchanged layers are rebuilt

**NuGet Package Caching**:
```yaml
- name: Setup .NET
  uses: actions/setup-dotnet@v4
  with:
    cache: true
    cache-dependency-path: '**/global.json'
```

### 4.2 Parallel Jobs

**Current Workflow**:
- PR Build: Runs on every PR (parallel ready)
- Deploy Workflow: Sequential (build → deploy-dev → promote-test)

**Improvement: Parallel Tests**:
```yaml
jobs:
  unit-tests:
    runs-on: ubuntu-latest
    steps:
      - run: dotnet test tests/CandidateApi.Tests --filter "Category=Unit"
  
  integration-tests:
    runs-on: ubuntu-latest
    steps:
      - run: dotnet test tests/CandidateApi.Tests --filter "Category=Integration"
  
  docker-build:
    needs: [unit-tests, integration-tests]
    runs-on: ubuntu-latest
    steps:
      - run: docker build -t candidate-api:latest .
```

### 4.3 Conditional Step Execution

**Only deploy if tests pass**:
```yaml
- name: Deploy to dev
  if: success()  # Only if previous steps succeeded
  run: kubectl apply -f k8s/dev/
```

**Skip deployment if hotfix**:
```yaml
- name: Deploy to test
  if: |
    success() &&
    !contains(github.event.head_commit.message, '[skip-test]')
  run: kubectl apply -f k8s/test/
```

### 4.4 Artifact Management

**Current**:
- NuGet packages stored in artifacts for 90 days
- Test results stored for 30 days

**Recommendation**: Set retention based on requirement
```yaml
- uses: actions/upload-artifact@v4
  with:
    name: nuget-package
    path: ./nuget-output/**/*.nupkg
    retention-days: 90  # Balance cost vs. compliance
```

---

## 5. Security Best Practices Summary

### Application Security
- ✅ Non-root user in containers
- ✅ Read-only root filesystem
- ✅ No elevated capabilities
- ✅ Health checks for dependency validation
- ✅ Security context enforced

### Pipeline Security
- ✅ Base image scanning (Trivy)
- ✅ Dependency vulnerability scanning (Dependabot)
- ✅ Static analysis (CodeQL)
- ✅ Secrets not printed to logs
- ✅ OIDC authentication to cloud providers

### Infrastructure Security
- ✅ Network policies restrict traffic
- ✅ RBAC limits pod permissions
- ✅ Secrets managed separately from config
- ✅ Pod disruption budgets prevent accidental outages

### Operational Security
- ✅ Deployment audit trail in git
- ✅ Role-based access to secrets
- ✅ Separate environments with different credentials
- ✅ Incident response runbooks

### Future Improvements
- [ ] Image signing and verification (Cosign)
- [ ] SBOM generation (CycloneDX)
- [ ] Runtime security (Falco)
- [ ] Policy enforcement (OPA/Gatekeeper)
- [ ] Secret rotation automation

---

## 6. Deployment Security Checklist

Before promoting to production, verify:

- [ ] Image scanned and no CRITICAL/HIGH vulnerabilities
- [ ] All dependencies up-to-date
- [ ] Static analysis passed (CodeQL)
- [ ] Secrets are not in logs or artifacts
- [ ] Network policies configured correctly
- [ ] RBAC permissions minimal
- [ ] Resource limits set appropriately
- [ ] Health checks configured
- [ ] Pod security context enforced
- [ ] Monitoring and alerting configured
- [ ] Incident response runbook reviewed
- [ ] Backup/restore procedures tested

---

## Related Resources

- Docker Security Best Practices: https://docs.docker.com/develop/dev-best-practices/
- Kubernetes Security: https://kubernetes.io/docs/concepts/security/
- GitHub Actions Security: https://docs.github.com/en/actions/security-guides
- OWASP Top 10: https://owasp.org/www-project-top-ten/
- CWE/CVE Database: https://nvd.nist.gov/

