FROM mcr.microsoft.com/dotnet/sdk:10
FROM mcr.microsoft.com/dotnet/sdk:10.0
FROM mcr.microsoft.com/dotnet/aspnet:10
FROM mcr.microsoft.com/dotnet/aspnet:10.0
# Multi-stage build for .NET API
FROM mcr.microsoft.com/dotnet/sdk:10.0.400-alpine AS builder

WORKDIR /src

# Copy solution and project files
COPY ["SreTakeHome.sln", "."]
COPY ["src/CandidateApi/CandidateApi.csproj", "src/CandidateApi/"]
COPY ["src/CandidateApi.Contracts/CandidateApi.Contracts.csproj", "src/CandidateApi.Contracts/"]
COPY ["tests/CandidateApi.Tests/CandidateApi.Tests.csproj", "tests/CandidateApi.Tests/"]
COPY ["global.json", "."]

# Restore dependencies
RUN dotnet restore

# Copy source code
COPY . .

# Build the solution
RUN dotnet build --configuration Release --no-restore SreTakeHome.sln

# Run tests
RUN dotnet test --configuration Release --no-build --verbosity normal SreTakeHome.sln

# Publish the API
RUN dotnet publish --configuration Release --no-build -o /app/publish src/CandidateApi/CandidateApi.csproj

# Create NuGet package for contracts
RUN dotnet pack --configuration Release --no-build -o /app/packages src/CandidateApi.Contracts/CandidateApi.Contracts.csproj

# Final runtime image
FROM mcr.microsoft.com/dotnet/aspnet:10.0.400-alpine AS runtime

WORKDIR /app

# Create non-root user for security
RUN useradd -m -u 1000 appuser

# Copy published application from builder
COPY --from=builder --chown=appuser:appuser /app/publish .

# Create read-only filesystem except for required directories
RUN mkdir -p /app/logs && chown appuser:appuser /app/logs

# Switch to non-root user
USER appuser

# Health check
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:8080/health/live || exit 1

# Expose port
EXPOSE 8080

# Set environment variables
ENV ASPNETCORE_URLS=http://+:8080
ENV ASPNETCORE_ENVIRONMENT=Production

ENTRYPOINT ["dotnet", "CandidateApi.dll"]
