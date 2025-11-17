# ============================================================================
# run-local.ps1 - Run k6 Load Test Locally Using Docker
# ============================================================================
# 
# Purpose:
#   Runs k6 load test script locally using Docker container. This is useful for:
#   - Quick testing before running distributed tests on AWS DLT
#   - Validating test scripts and configurations
#   - Testing without AWS infrastructure
#
# Prerequisites:
#   - Docker Desktop installed and running
#   - Required environment variables set
#
# Usage:
#   .\run-local.ps1
#   .\run-local.ps1 -Scenario "quick"
#   .\run-local.ps1 -Scenario "normal"
#   .\run-local.ps1 -Scenario "peak"
#
# Parameters:
#   -Scenario    Test scenario to run (default: "quick")
#                Options: "quick" | "normal" | "peak"
#
# What This Script Does:
#   1. Validates required environment variables
#   2. Checks if Docker is installed and running
#   3. Pulls k6 Docker image if not available
#   4. Runs k6 test script (load-test-k6.js) in Docker container
#   5. Displays test results
#
# Test Configuration:
#   - Test scenarios and settings are defined in load-test-k6.js
#   - Configuration is embedded in the k6 script (export const options)
#   - Environment variables are passed to k6 container
#
# ============================================================================
# REQUIRED ENVIRONMENT VARIABLES
# ============================================================================
#   LOADTEST_SHOPIFY_URL      - Shopify store URL (without https://)
#                               Example: your-store.myshopify.com
#
#   LOADTEST_SHOPIFY_TOKEN    - Shopify Admin API access token
#                               Example: shpat_xxxxx
#
# ============================================================================
# OPTIONAL ENVIRONMENT VARIABLES
# ============================================================================
#   LOADTEST_SPECIAL_SKUS_RATE - Percentage of orders with special SKUs (gift cards)
#                                Format: Decimal (0.00 to 1.00)
#                                Examples:
#                                  0.01 = 1% of orders
#                                  0.05 = 5% of orders
#                                  0.10 = 10% of orders
#                                Default: 0.01 (1%)
#
# ============================================================================
# HOW ENVIRONMENT VARIABLES ARE USED
# ============================================================================
#   Environment variables are passed to k6 Docker container.
#   In the k6 script (load-test-k6.js), access them using:
#     __ENV.SHOPIFY_URL
#     __ENV.SHOPIFY_TOKEN
#     __ENV.SPECIAL_SKUS_RATE
#     __ENV.SCENARIO
#
# ============================================================================

param(
    [Parameter(Mandatory=$false)]
    [string]$Scenario = "quick"  # Optional: test scenario (quick|normal|peak)
)

# ============================================
# Helper Functions
# ============================================
function Validate-EnvironmentVariables {
    $required = @("LOADTEST_SHOPIFY_URL", "LOADTEST_SHOPIFY_TOKEN")
    $missing = $required | Where-Object { [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($_)) }
    
    if ($missing.Count -gt 0) {
        Write-Error "Missing required environment variables: $($missing -join ', ')"
        Write-Host "Set environment variables:" -ForegroundColor Yellow
        foreach ($var in $missing) {
            Write-Host "  `$env:$var = 'value'" -ForegroundColor Gray
        }
        Write-Host ""
        Write-Host "Example:" -ForegroundColor Yellow
        Write-Host "  `$env:LOADTEST_SHOPIFY_URL = 'your-store.myshopify.com'" -ForegroundColor Gray
        Write-Host "  `$env:LOADTEST_SHOPIFY_TOKEN = 'shpat_xxxxx'" -ForegroundColor Gray
        exit 1
    }
}

function Check-Docker {
    $dockerCheck = docker --version 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Docker not found. Please install Docker Desktop: https://www.docker.com/products/docker-desktop"
        exit 1
    }
    Write-Host "[INFO] Docker found: $dockerCheck" -ForegroundColor Green
}

function Ensure-K6Image {
    $imageExists = docker images grafana/k6:latest -q 2>&1
    if ([string]::IsNullOrEmpty($imageExists)) {
        Write-Host "[INFO] Pulling k6 Docker image..." -ForegroundColor Yellow
        docker pull grafana/k6:latest
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Failed to pull k6 image"
            exit 1
        }
    }
}

# ============================================
# Main Execution
# ============================================
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Local Shopify Order Load Test (k6 via Docker)" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Get paths
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$scriptName = "load-test-k6.js"
$scriptPath = Join-Path $scriptDir $scriptName

if (-not (Test-Path $scriptPath)) {
    Write-Error "Script not found: $scriptPath"
    exit 1
}

Write-Host "[INFO] Test Configuration:" -ForegroundColor Blue
Write-Host "  Config Source: Embedded in k6 script (export const options)"
Write-Host "  Script: $scriptName"
Write-Host "  Scenario: $Scenario"
Write-Host ""

# Step 1: Validate environment variables
Validate-EnvironmentVariables

# Display configuration
Write-Host "[INFO] Environment:" -ForegroundColor Blue
Write-Host "  Shopify URL: $env:LOADTEST_SHOPIFY_URL"
Write-Host "  Shopify Token: $($env:LOADTEST_SHOPIFY_TOKEN.Substring(0, [Math]::Min(20, $env:LOADTEST_SHOPIFY_TOKEN.Length)))..."
Write-Host "  Scenario: $Scenario"

if ($env:LOADTEST_SPECIAL_SKUS_RATE) {
    Write-Host "  Special SKUs Rate: $env:LOADTEST_SPECIAL_SKUS_RATE"
} else {
    Write-Host "  Special SKUs Rate: 0.01 (1% default)"
}

Write-Host ""

# Step 2: Check Docker availability
Check-Docker
Write-Host ""

# Step 3: Ensure k6 image exists
Write-Host "[INFO] Checking k6 Docker image..." -ForegroundColor Blue
Ensure-K6Image

Write-Host "[INFO] Resolved script: $scriptPath" -ForegroundColor Blue

Write-Host "[INFO] Running k6 Shopify order load test..." -ForegroundColor Blue
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Run k6 test
Write-Host "[INFO] Starting k6 load test..." -ForegroundColor Blue
Write-Host ""

# Build environment variables array for Docker
$envVars = @(
    "-e SHOPIFY_URL=`"$env:LOADTEST_SHOPIFY_URL`"",
    "-e SHOPIFY_TOKEN=`"$env:LOADTEST_SHOPIFY_TOKEN`"",
    "-e SCENARIO=`"$Scenario`""
)

# Add optional environment variables if set
if ($env:LOADTEST_SPECIAL_SKUS_RATE) {
    $envVars += "-e SPECIAL_SKUS_RATE=`"$env:LOADTEST_SPECIAL_SKUS_RATE`""
}


# Build Docker command
$dockerCmd = "docker run --rm -i " + ($envVars -join " ") + " -v `"${scriptDir}:/scripts`" grafana/k6 run /scripts/$scriptName"

# Execute Docker command
Invoke-Expression $dockerCmd

$exitCode = $LASTEXITCODE

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
if ($exitCode -eq 0) {
    Write-Host "[SUCCESS] Test completed successfully!" -ForegroundColor Green
} else {
    Write-Host "[FAILED] Test failed with exit code: $exitCode" -ForegroundColor Red
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

exit $exitCode

