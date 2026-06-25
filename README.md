# SRE Take-Home Assessment

## Instructions

Fork this repository and follow the guidelines below. When you are finished, or when you have run out of time, share a link to your forked repository back with the hiring team for review.

- **Mid-Level SRE candidates**: Complete the base assignment below. Try to spend **4 hours or less**.
- **Senior SRE candidates**: Complete the base assignment **and** pick 2 items from the [Senior SRE Extension](#senior-sre-extension). Try to spend **6 hours or less**.

This exercise is intentionally open-ended. We care about how you approach the work, how you communicate tradeoffs, and how you shape a delivery pipeline around a realistic application.

## The Assignment

As an SRE at Coterie, you will often need to stand up CI/CD pipelines for application teams shipping .NET services. A common scenario is a .NET API that needs to be built, tested, containerized, packaged, and deployed to Kubernetes by GitHub Actions.

This repository contains a .NET 10 solution with:

- A Web API project at `src/CandidateApi`
- A contracts library at `src/CandidateApi.Contracts` that should be packaged as a NuGet package
- A unit test project at `tests/CandidateApi.Tests`

The API is intentionally simple so you can focus on delivery and operations work instead of application development. It includes:

- `GET /` for service metadata
- `GET /health/live` for liveness
- `GET /health/ready` for readiness based on configured dependencies
- `GET /api/work-items` for sample application data

## What You Should Build

Create two GitHub Actions workflows:

1. When a developer opens or updates a pull request, trigger a build of the solution and run unit tests.
2. When changes are merged into the `main` branch, trigger a build and deploy to a development environment. If development succeeds, automatically promote the same build to a test environment.

Your target deployment platform should be a Kubernetes cluster or clusters.

## Requirements

- A build is triggered from a pull request
- A build and deployment are triggered from a push to `main`
- A Dockerfile is created that containerizes the .NET API and is built in CI
- A NuGet package is produced from `CandidateApi.Contracts` as part of the build
- Two environments are configured: development and test
- The .NET API is deployed to both environments
- The deployment approach is documented clearly enough for a reviewer to follow

## Local Development

The repo is pinned to .NET 10 through `global.json`.

Typical commands:

```bash
dotnet restore
dotnet build SreTakeHome.sln
dotnet test SreTakeHome.sln
dotnet run --project src/CandidateApi/CandidateApi.csproj --urls http://localhost:5000
```

Once the API is running, useful endpoints are:

- `http://localhost:5000/`
- `http://localhost:5000/health/live`
- `http://localhost:5000/health/ready`
- `http://localhost:5000/api/work-items`

If you want to simulate a failing readiness check, update the dependency values under `CandidateApi` in `src/CandidateApi/appsettings.json` or use environment-specific configuration.

## Expectations

There are a lot of moving parts here: .NET builds, unit tests, Docker images, NuGet packaging, GitHub Actions workflows, environment promotion, and Kubernetes deployments. A 100% complete solution is welcome, but not required.

If you do not have access to infrastructure needed to fully deploy the service, it is okay to mock pieces of the solution. You can use placeholder manifests, commented workflow steps, or documented assumptions. If you want a fully working deployment target, feel free to use a free or trial environment such as Microsoft Azure or another provider.

During the technical interview, you will be expected to walk through your submission. At a minimum, you should have the application running and accessible locally so you can demonstrate it live.

We value:

- Clear automation and repeatability
- Practical tradeoff decisions
- Thoughtful documentation
- Sensible security and secret handling
- Observability and deployment safety considerations

## What To Submit

Please include:

- Your GitHub Actions workflow files
- Any Docker or Kubernetes manifests you created
- Notes about assumptions, tradeoffs, or incomplete pieces
- Instructions a reviewer can use to validate your solution

---

## Senior SRE Extension

If you are interviewing for a **Senior Site Reliability Engineer** role, please complete the base assignment above **and** 2 additional items from below. These extensions reflect the deeper ownership, observability expertise, and infrastructure maturity we expect from senior engineers on the team.

You are not expected to complete every item. Pick 2 areas where you can demonstrate the most depth and explain your reasoning for what you prioritized.

### Observability & SLOs

- Instrument the API with meaningful metrics (request latency, error rates, saturation) and define at least one **SLI/SLO** for the service. Document the SLO target, the error budget, and how you would alert on budget burn rate.
- Provide a Grafana dashboard definition (JSON model or provisioning config) that visualizes the SLIs you defined. If you don't have a running Grafana instance, a checked-in dashboard JSON with documentation is fine.
- Configure structured logging and demonstrate how logs would be aggregated (e.g., Loki, Application Insights, or equivalent).

### Infrastructure as Code

- Define the infrastructure needed to run the service using an IaC tool (Pulumi, Terraform, Bicep, or similar). This should cover at minimum the Kubernetes cluster, container registry, and any supporting resources (networking, DNS, secrets management).
- Structure the IaC so that development and test environments are provisioned from the same modules with environment-specific configuration. Show how you would manage state and prevent drift.

### Advanced Kubernetes & Deployment Strategy

- Implement a deployment strategy beyond basic rolling updates (e.g., blue-green, canary with automated rollback). Document the tradeoffs of your chosen approach.
- Add production-hardening to your Kubernetes manifests: resource requests/limits, pod disruption budgets, network policies, security contexts (non-root, read-only filesystem), and horizontal pod autoscaling.
- Configure health check integration so that Kubernetes liveness and readiness probes use the API's `/health/live` and `/health/ready` endpoints with appropriate thresholds.

### Incident Response & Operational Readiness

- Write a **runbook** for at least one failure scenario (e.g., the readiness check fails, deployment rollback is needed, or a dependent service is degraded). Include detection, diagnosis steps, and remediation.
- Describe or implement an alerting strategy: what conditions fire alerts, severity levels, escalation paths, and how you would reduce alert fatigue.

### CI/CD Maturity

- Add security scanning to the pipeline (container image scanning, dependency vulnerability checks, or static analysis).
- Implement pipeline optimizations such as build caching, parallel jobs, or conditional step execution.
- Show how secrets and environment-specific configuration are managed across environments without hardcoding values in workflows or manifests.

### Senior-Level Expectations

In addition to the base assessment criteria, senior candidates will be evaluated on:

- **Systems thinking**: Do your choices account for failure modes, scalability, and operational burden?
- **Depth of reasoning**: Can you articulate *why* you chose an approach over alternatives?
- **Production readiness**: Would your solution survive a real incident with minimal manual intervention?
- **Observability maturity**: Do your metrics, logs, and alerts tell a coherent story about service health?
- **Mentorship signal**: Is your documentation clear enough that a junior engineer could follow it and learn from it?

---

## Questions

Feel free to reach out with questions or concerns regarding the assessment. This is a free-form exercise on purpose, and there are multiple reasonable ways to approach it.
