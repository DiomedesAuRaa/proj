# Observability, SLIs, SLOs & Alerting Strategy

## Overview

This document defines Service Level Indicators (SLIs), Service Level Objectives (SLOs), error budgets, and observability recommendations for the Candidate API service.

---

## 1. Service Level Objectives (SLOs)

### 1.1 Primary SLO: Availability

**Definition**: The percentage of successful requests (HTTP 2xx/3xx) that complete within the target latency.

**SLO Target**: **99.5%** (for development and test environments)

**Production Target** (Recommended): **99.9%**

| Environment | SLO Target | Error Budget/Month |
|------------|-----------|------------------|
| Development | 99.5% | 3.6 hours |
| Test | 99.5% | 3.6 hours |
| Production | 99.9% | 43.2 minutes |

### 1.2 SLO Components

**Error Rate SLI**:
- Definition: (1 - (error_responses / total_responses)) × 100%
- Target: ≥ 99.5%
- Meaning: Fewer than 5 failed requests per 1000

**Latency SLI**:
- Definition: (requests_completing_under_threshold / total_requests) × 100%
- P95 Latency Target: < 100ms
- P99 Latency Target: < 500ms
- Meaning: 99% of requests respond within 100ms

**Availability SLI**:
- Definition: (requests_reaching_service / total_requests) × 100%
- Target: ≥ 99.5%
- Meaning: Service is reachable and responsive

### 1.3 Service Dependencies

The API depends on:
- **PostgreSQL Database**: Required for data persistence
- **Redis Cache**: Required for performance (used for session management)
- **Third-party Billing Service**: Required for business operations

Each dependency failure impacts the overall SLO.

**Dependency Health Strategy**:
```
If Postgres unavailable → Readiness check fails → Pod removed from load balancing → User request handled by other pod or service unavailable
If Redis unavailable → Readiness check fails → Similar behavior
If Billing Service unavailable → Marked in health response → Users get informational response
```

---

## 2. Error Budget

### 2.1 Error Budget Calculation

**Monthly Error Budget** (99.5% target):
```
Total minutes in month = 30 × 24 × 60 = 43,200 minutes
Uptime = 99.5% = 43,200 × 0.995 = 42,984 minutes
Error budget = 43,200 - 42,984 = 216 minutes (~3.6 hours)
```

### 2.2 Budget Burn Rate Monitoring

**Burn Rate Alerts**:
```
Fast Burn (1x): Uses entire monthly budget in 30 days (66 events in 5 minutes)
  → Alert: "Service approaching SLO breach"
  → Action: Page on-call engineer

Slow Burn (0.1x): Uses entire monthly budget in 300 days (6.6 events in 5 minutes)
  → Alert: "Service at risk over time"
  → Action: Investigate trends, schedule improvement work

Critical Burn (10x): Uses entire budget in 3 days (660 events in 5 minutes)
  → Alert: "SLO will be breached"
  → Action: Immediate incident response
```

### 2.3 Budget Usage Example

**If service experiences 30 minutes downtime**:
- 30 minutes out of 216-minute budget
- ~13.9% of monthly budget consumed
- Remaining budget: 186 minutes (1.2x the burn rate limit)
- Recommendation: Implement fixes before next incident

---

## 3. Monitoring Strategy

### 3.1 Key Metrics (The "Four Golden Signals")

#### 1. Latency
**What to measure**: How long requests take to complete

**Metrics**:
```
- Request latency (by endpoint)
  - GET / : P50, P95, P99
  - GET /health/live : P50, P95, P99
  - GET /health/ready : P50, P95, P99
  - GET /api/work-items : P50, P95, P99

- Dependency latency
  - Database query time
  - Cache access time
  - Billing service response time
```

**Prometheus Query Examples**:
```promql
# P95 latency for all requests
histogram_quantile(0.95, http_request_duration_seconds_bucket)

# P99 latency by endpoint
histogram_quantile(0.99, http_request_duration_seconds_bucket{path=~"/api/.*"})

# Latency trend over time
rate(http_request_duration_seconds_sum[5m]) / rate(http_request_duration_seconds_count[5m])
```

#### 2. Error Rate
**What to measure**: Percentage of failed requests

**Metrics**:
```
- HTTP error rate (by status code)
  - 4xx (client errors): /health/live, /health/ready
  - 5xx (server errors): All endpoints
  - Timeouts: Requests exceeding timeout
  
- Error rate by endpoint
  - GET /
  - GET /api/work-items
  
- Application exceptions
  - NullReferenceException
  - DatabaseException
  - TimeoutException
```

**Prometheus Query Examples**:
```promql
# Overall error rate
rate(http_requests_total{status=~"5.."}[5m]) / rate(http_requests_total[5m])

# 5xx error rate trend
rate(http_requests_total{status=~"5.."}[5m])

# Error rate by endpoint
rate(http_requests_total{status=~"5..",path="/api/work-items"}[5m])
```

#### 3. Saturation
**What to measure**: How utilized service resources are

**Metrics**:
```
- CPU utilization
- Memory usage
- Disk I/O
- Network bandwidth
- Database connection pool usage
- Cache hit/miss ratio
- Request queue depth
```

**Prometheus Query Examples**:
```promql
# CPU usage percentage
rate(process_cpu_seconds_total[5m]) * 100

# Memory usage
process_resident_memory_bytes / 1024 / 1024  # in MB

# Requests in queue (pending)
http_requests_pending

# Database connection pool utilization
db_connection_pool_used / db_connection_pool_max
```

#### 4. Traffic
**What to measure**: How many requests the service handles

**Metrics**:
```
- Request rate (requests per second)
- Request distribution by endpoint
- Request distribution by method (GET, POST, etc.)
- Request distribution by client
```

**Prometheus Query Examples**:
```promql
# Requests per second
rate(http_requests_total[5m])

# Requests per second by endpoint
rate(http_requests_total[5m]) by (path)

# Requests per second by status
rate(http_requests_total[5m]) by (status)
```

### 3.2 Application Instrumentation

**Add to Program.cs**:
```csharp
using Prometheus;

// Add metrics
var httpRequestDuration = Metrics.CreateHistogram(
    "http_request_duration_seconds",
    "HTTP request duration in seconds",
    new HistogramConfiguration
    {
        Buckets = Histogram.ExponentialBuckets(0.001, 2, 10)
    },
    labelNames: new[] { "method", "path", "status" });

var httpRequestsTotal = Metrics.CreateCounter(
    "http_requests_total",
    "Total HTTP requests",
    labelNames: new[] { "method", "path", "status" });

var applicationExceptions = Metrics.CreateCounter(
    "application_exceptions_total",
    "Total application exceptions",
    labelNames: new[] { "exception_type" });

// Middleware to record metrics
app.Use(async (context, next) =>
{
    var startTime = DateTime.UtcNow;
    try
    {
        await next();
        var duration = (DateTime.UtcNow - startTime).TotalSeconds;
        httpRequestDuration.Labels(context.Request.Method, context.Request.Path, context.Response.StatusCode.ToString()).Observe(duration);
        httpRequestsTotal.Labels(context.Request.Method, context.Request.Path, context.Response.StatusCode.ToString()).Inc();
    }
    catch (Exception ex)
    {
        applicationExceptions.Labels(ex.GetType().Name).Inc();
        throw;
    }
});

// Expose metrics endpoint
app.MapMetrics();
```

---

## 4. Alerting Strategy

### 4.1 Alert Philosophy

**Goal**: Alert on symptoms that require human action, not on root causes.

**Bad Alert**: "High CPU usage" (might be normal if processing large batch)
**Good Alert**: "Error rate > SLO for 5 minutes" (requires investigation)

### 4.2 Alert Rules

**Alert 1: Error Rate Exceeds SLO (High Urgency)**
```yaml
groups:
- name: candidate-api
  rules:
  - alert: HighErrorRate
    expr: |
      (rate(http_requests_total{status=~"5.."}[5m]) /
       rate(http_requests_total[5m])) > 0.005
    for: 5m
    severity: critical
    annotations:
      summary: "Candidate API error rate > 0.5%"
      description: "Error rate is {{ $value | humanizePercentage }} (target: 0.5%)"
      runbook: "https://wiki.internal/runbooks/high-error-rate"
```

**Alert 2: Error Rate Burn Rate (Medium Urgency)**
```yaml
  - alert: ErrorRateBurnRate
    expr: |
      (rate(http_requests_total{status=~"5.."}[5m]) /
       rate(http_requests_total[5m])) > 0.001
    for: 30m
    severity: warning
    annotations:
      summary: "Candidate API approaching SLO breach"
      description: "Error rate {{ $value | humanizePercentage }} will breach SLO"
```

**Alert 3: P95 Latency Exceeds Target**
```yaml
  - alert: HighLatency
    expr: |
      histogram_quantile(0.95, 
        rate(http_request_duration_seconds_bucket[5m])) > 0.1
    for: 5m
    severity: warning
    annotations:
      summary: "Candidate API P95 latency > 100ms"
      description: "P95 latency is {{ $value | humanizeDuration }}"
```

**Alert 4: Pod Readiness Failing**
```yaml
  - alert: PodReadinessFailing
    expr: |
      kube_pod_status_ready{pod=~"candidate-api.*",condition="false"} > 0
    for: 2m
    severity: critical
    annotations:
      summary: "{{ $labels.pod }} not ready in {{ $labels.namespace }}"
      description: "Pod has been unready for {{ $value }} minutes"
```

**Alert 5: Memory Usage High**
```yaml
  - alert: HighMemoryUsage
    expr: |
      (container_memory_usage_bytes / container_spec_memory_limit_bytes) > 0.85
    for: 5m
    severity: warning
    annotations:
      summary: "{{ $labels.pod }} memory usage > 85%"
      description: "Memory usage is {{ $value | humanizePercentage }}"
```

**Alert 6: CPU Throttling**
```yaml
  - alert: CPUThrottling
    expr: |
      rate(container_cpu_cfs_throttled_seconds_total[5m]) > 0
    for: 5m
    severity: warning
    annotations:
      summary: "{{ $labels.pod }} experiencing CPU throttling"
```

### 4.3 Alerting Rules Best Practices

1. **Alert on user-facing symptoms** (error rate, latency)
2. **Avoid alert fatigue** (require 5+ minute sustained condition)
3. **Use severity levels**: critical, warning, info
4. **Include runbook link** (how to fix it)
5. **Include context** (which environment, which pod)
6. **Suppress known maintenance windows**

### 4.4 Alert Escalation

```
Level 1: Warning (threshold exceeded)
  - Slack notification to #incidents channel
  - 10-minute timeout to resolve
  
Level 2: Critical (SLO breach + warning unresolved)
  - Page on-call engineer
  - 2-minute timeout to acknowledge
  
Level 3: Cascading (multiple alerts firing)
  - Page incident commander
  - Open bridge call
  - Declare SEV1 if customer-facing
```

---

## 5. Logging Strategy

### 5.1 Structured Logging

**Current**: Default .NET logging

**Recommended**: Structured logging with JSON

**Implementation with Serilog**:
```csharp
// Install: dotnet add package Serilog.AspNetCore
// Install: dotnet add package Serilog.Sinks.Console

using Serilog;
using Serilog.Formatting.Json;

var builder = WebApplication.CreateBuilder(args);

// Configure Serilog
var logger = new LoggerConfiguration()
    .MinimumLevel.Debug()
    .WriteTo.Console(new JsonFormatter())
    .WriteTo.File("logs/candidate-api-.log", 
        rollingInterval: RollingInterval.Day,
        outputTemplate: "{Timestamp:yyyy-MM-dd HH:mm:ss.fff zzz} [{Level:u3}] {Message:lj}{NewLine}{Exception}")
    .CreateLogger();

builder.Logging.ClearProviders();
builder.Logging.AddSerilog(logger);

var app = builder.Build();

// Structured logging in handlers
app.MapGet("/api/work-items", (ILogger<Program> logger) =>
{
    logger.LogInformation("GetWorkItems called by {IpAddress}", 
        HttpContext.Connection.RemoteIpAddress);
    
    try
    {
        var items = new[] { /* ... */ };
        logger.LogInformation("Returning {ItemCount} work items", items.Length);
        return Results.Ok(items);
    }
    catch (Exception ex)
    {
        logger.LogError(ex, "Error retrieving work items");
        throw;
    }
});
```

### 5.2 Log Aggregation

**Recommended Options**:
1. **Grafana Loki** (open-source, lightweight)
2. **Azure Application Insights** (if on Azure)
3. **ELK Stack** (Elasticsearch, Logstash, Kibana)
4. **DataDog** (SaaS, comprehensive)

**Loki Example** (Kubernetes DaemonSet):
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: loki-config
  namespace: monitoring
data:
  loki-config.yaml: |
    auth_enabled: false
    ingester:
      chunk_idle_period: 3m
      max_chunk_age: 1h
      max_streams_matcher_size: 0
    limits_config:
      enforce_metric_name: false
      reject_old_samples: true
      reject_old_samples_max_age: 168h
    schema_config:
      configs:
      - from: 2020-10-24
        store: boltdb-shipper
        object_store: filesystem
        schema: v11
        index:
          prefix: index_
          period: 24h
    server:
      http_listen_port: 3100
    storage_config:
      boltdb_shipper:
        active_index_directory: /loki/boltdb-shipper-active
        cache_location: /loki/boltdb-shipper-cache
        shared_store: filesystem
      filesystem:
        directory: /loki/chunks
```

### 5.3 Log Retention

**Development**: 7 days (for debugging)
**Test**: 30 days (for audit)
**Production**: 90 days (for compliance)

---

## 6. Observability Dashboard

### 6.1 Recommended Metrics for Grafana Dashboard

**Top Section - Summary**:
- Current error rate (big number)
- Current P95 latency (big number)
- Service availability (percentage)
- Number of pods ready/total

**Second Row - Time Series**:
- Error rate over time (24h)
- Latency (P50, P95, P99) over time
- Request rate (RPS) over time
- HTTP status code distribution

**Third Row - Saturation**:
- CPU usage by pod
- Memory usage by pod
- Network I/O
- Disk usage

**Bottom Row - Dependencies**:
- Dependency health status
- Database connection pool usage
- Cache hit/miss ratio
- Third-party service latency

### 6.2 Grafana Dashboard JSON Example

See `OBSERVABILITY_DASHBOARD.json` (in repo root) for complete dashboard definition.

---

## 7. Recommended Observability Stack

### Minimal Setup (Open Source)

```
Prometheus (Metrics Collection)
  ↓
Grafana (Visualization)
  ↓
Alertmanager (Alert Routing)

Loki (Log Aggregation)
  ↓
Grafana (Log Visualization)

Application (Structured Logging)
  ↓
Stdout/File
  ↓
Loki Promtail (Log Collector)
```

### Production Setup (SaaS)

```
OpenTelemetry Instrumentation (App)
  ↓
DataDog / Honeycomb / New Relic
  ↓
Metrics, Logs, Traces, Profiles (Unified)
```

---

## 8. SLO Implementation Roadmap

### Phase 1: Foundation (Week 1-2)
- [ ] Deploy Prometheus + Grafana in dev cluster
- [ ] Instrument application with basic metrics
- [ ] Define SLIs and SLOs
- [ ] Create alert rules
- [ ] Test alerts with synthetic traffic

### Phase 2: Hardening (Week 3-4)
- [ ] Add distributed tracing (Jaeger/Tempo)
- [ ] Implement structured logging with Loki
- [ ] Create comprehensive dashboards
- [ ] Document SLO thresholds and error budgets
- [ ] Train team on observability

### Phase 3: Automation (Week 5-6)
- [ ] Integrate SLO tracking into CI/CD
- [ ] Automated SLO burn rate analysis
- [ ] Slack notifications for SLO breaches
- [ ] Weekly SLO reports
- [ ] Capacity planning based on trends

---

## Summary

### Key Takeaways

**SLO**: 99.5% availability (for dev/test)
**Error Budget**: 216 minutes per month (~3.6 hours)
**Primary Metrics**: Latency, Error Rate, Saturation, Traffic
**Alert Strategy**: Page on-call if error rate > 0.5% for 5 minutes
**Observability**: Prometheus + Grafana + Loki

This provides a foundation for operational excellence and data-driven decision making.

---

## Related Files

- Alerting rules: `.github/monitoring/alerts.yaml`
- Grafana dashboard: `OBSERVABILITY_DASHBOARD.json`
- Loki configuration: `.github/monitoring/loki-config.yaml`
- Application metrics instrumentation: `src/CandidateApi/Program.cs`
