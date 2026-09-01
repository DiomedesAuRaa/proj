FROM mcr.microsoft.com/dotnet/sdk:10
# Multi-stage build for .NET API
FROM mcr.microsoft.com/dotnet/sdk:10.0.400-noble AS builder

WORKDIR /src

# Copy project files for dependency caching
COPY ["src/CandidateApi/CandidateApi.csproj", "src/CandidateApi/"]
COPY ["src/CandidateApi.Contracts/CandidateApi.Contracts.csproj", "src/CandidateApi.Contracts/"]
COPY ["global.json", "."]

# Restore dependencies
RUN dotnet restore src/CandidateApi/CandidateApi.csproj

# Copy source code
COPY . .

# Build the API
RUN dotnet build --configuration Release --no-restore src/CandidateApi/CandidateApi.csproj

# Publish the API
RUN dotnet publish --configuration Release --no-build -o /app/publish src/CandidateApi/CandidateApi.csproj

# Final runtime image
FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS runtime

WORKDIR /app

# Copy published application from builder
COPY --from=builder --chown=app:app /app/publish .

# Create read-only filesystem except for required directories
RUN mkdir -p /app/logs && chown app:app /app/logs

# Switch to non-root user
USER app

# Health check
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:8080/health/live || exit 1

# Expose port
EXPOSE 8080

# Set environment variables
ENV ASPNETCORE_URLS=http://+:8080
ENV ASPNETCORE_ENVIRONMENT=Production

ENTRYPOINT ["dotnet", "CandidateApi.dll"]
