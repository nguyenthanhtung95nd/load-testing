# ============================================================================
# trigger-dlt.ps1 - Trigger Distributed Load Test on AWS DLT
# ============================================================================
# 
# Purpose:
#   Uploads k6 test script to S3 and triggers distributed load test on AWS DLT
#   infrastructure. The test will run on multiple ECS containers in parallel.
#
# Usage:
#   .\trigger-dlt.ps1
#   .\trigger-dlt.ps1 -Scenario "quick"
#   .\trigger-dlt.ps1 -Scenario "normal"
#   .\trigger-dlt.ps1 -Scenario "peak"
#
# Parameters:
#   -Scenario    Test scenario to run (default: "normal")
#                Options: "quick" | "normal" | "peak"
#
# What This Script Does:
#   1. Uploads k6 script (load-test-k6.js) to S3 bucket
#   2. Sends test configuration to DLT API Gateway
#   3. DLT starts test on ECS containers
#   4. Returns Test ID for tracking results
#
# File Locations:
#   - Script uploaded to: s3://{bucket}/public/test-scenarios/k6/{testId}.js
#   - Results saved to:    s3://{bucket}/results/{testId}/
#
# ============================================================================
# REQUIRED ENVIRONMENT VARIABLES
# ============================================================================
#   LOADTEST_DLT_API          - DLT API Gateway endpoint
#                               Example: https://xxx.execute-api.region.amazonaws.com/prod
#
#   LOADTEST_SCRIPTS_BUCKET   - S3 bucket name for scripts and results
#                               Example: sample-loadtest-dlt-scenariosbucket-xxx
#
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
#   All environment variables are passed to k6 containers running on ECS.
#   In the k6 script (load-test-k6.js), access them using:
#     __ENV.SHOPIFY_URL
#     __ENV.SHOPIFY_TOKEN
#     __ENV.SPECIAL_SKUS_RATE
#     __ENV.SCENARIO
#
# ============================================================================

param(
  [string]$Scenario = "normal"
)

function Fail($msg) { 
  Write-Error $msg
  exit 1 
}

function Require-Env {
  param([string[]]$Names)
  $missing = @()
  foreach ($n in $Names) { 
    $val = [Environment]::GetEnvironmentVariable($n)
    if ([string]::IsNullOrEmpty($val)) { $missing += $n } 
  }
  if ($missing.Count -gt 0) {
    Fail "Missing env vars: $($missing -join ', '). Set via `$env:<NAME>='value'"
  }
}

function Get-ApiParts {
  param([string]$Url)
  if ($Url -notmatch 'https://([a-z0-9]+)\.execute-api\.([-\w]+)\.amazonaws\.com/([^/?#]+)') {
    Fail "Invalid LOADTEST_DLT_API format: $Url"
  }
  [pscustomobject]@{ ApiId=$matches[1]; Region=$matches[2]; Stage=$matches[3] }
}

function S3-Upload {
  param([string]$LocalPath, [string]$Bucket, [string]$Key, [string]$Region)
  
  if (-not (Test-Path $LocalPath)) {
    Fail "Local file not found: $LocalPath"
  }
  
  Write-Host "Uploading to s3://$Bucket/$Key..." -ForegroundColor Gray
  
  # Try to delete first (best effort)
  aws s3 rm "s3://$Bucket/$Key" --region $Region 2>&1 | Out-Null
  
  aws s3 cp $LocalPath "s3://$Bucket/$Key" --region $Region 2>&1 | Out-Null
  if ($LASTEXITCODE -ne 0) { 
    Fail "Upload to s3://$Bucket/$Key failed (exit code: $LASTEXITCODE)" 
  }
}

function Build-Payload {
  param(
    [string]$TestId,
    [string]$Script,
    [string]$Region,
    [string]$ShopifyUrl,
    [string]$ShopifyToken,
    [string]$Scenario
  )

  # Scenario name must match script name (without .js extension)
  # Pattern: {script-name} (e.g., load-test-k6.js -> load-test-k6)
  $scenarioName = $Script.Replace(".js","")
  
  # DLT settings mapping based on scenario
  # DLT overrides these k6 settings:
  # - Task Count (DLT) → controls number of containers
  # - Concurrency (DLT) → controls VUs per container (overrides preAllocatedVUs)
  # - Ramp Up (DLT) → controls ramp-up time
  # - Hold For (DLT) → controls test duration (overrides duration)
  $scenarioSettings = @{
    'quick' = @{
      TaskCount = 1
      Concurrency = 1       # Matches k6: vus=1
      RampUp = '10s'        # Short ramp-up
      HoldFor = '300s'      # 5 minutes (test runs for 5 minutes)
    }
    
    'normal' = @{
      TaskCount = 1
      Concurrency = 5       # Matches k6: vus=5
      RampUp = '60s'        # 1 minute ramp-up
      HoldFor = '3600s'     # 60 minutes (test runs for 60 minutes)
    }
    
    'peak' = @{
      TaskCount = 1
      Concurrency = 10      # Matches k6: vus=10
      RampUp = '30s'        # 30 seconds ramp-up
      HoldFor = '1800s'     # 30 minutes (test runs for 30 minutes)
    }
  }
  # Get settings for selected scenario, default to normal if not found
  $settings = $scenarioSettings[$Scenario]
  if (-not $settings) {
    Write-Warning "Unknown scenario '$Scenario', using 'normal' settings"
    $settings = $scenarioSettings['normal']
  }
  
  # Environment variables for k6 containers
  $envVars = @{
    SHOPIFY_URL = $ShopifyUrl
    SHOPIFY_TOKEN = $ShopifyToken
    SCENARIO = $Scenario
  }
  
  # Add optional environment variables if set
  if ($env:LOADTEST_SPECIAL_SKUS_RATE) {
    $envVars.SPECIAL_SKUS_RATE = $env:LOADTEST_SPECIAL_SKUS_RATE
  }
  
  $exec = @()
  $execItem = @{
    'ramp-up' = $settings.RampUp
    'hold-for' = $settings.HoldFor
    scenario = $scenarioName
    executor = 'k6'
    env = $envVars  # Env vars needed in execution block for DLT
  }
  $exec += $execItem
  
  # Scenario definition with script and env vars
  $scenariosMap = @{}
  $scenariosMap[$scenarioName] = @{ 
    script = "$TestId.js"
    env = $envVars
  }

  # Payload matching UI format + env vars for k6
  # Note: env vars are in scenarios[scenarioName].env for Taurus/k6 compatibility
  return @{
    testId                = $TestId
    testName              = $scenarioName
    testDescription       = "$scenarioName description"
    testTaskConfigs       = @(
      @{
        concurrency = [string]$settings.Concurrency
        taskCount = [string]$settings.TaskCount
        region = $Region
      }
    )
    testScenario          = @{
      execution = $exec
      scenarios = $scenariosMap
    }
    showLive              = $true
    testType              = 'k6'
    fileType              = 'script'
    regionalTaskDetails   = @{
      $Region = @{
        vCPULimit         = 64
        vCPUsPerTask      = 2
        vCPUsInUse        = 0
        dltTaskLimit      = 32
        dltAvailableTasks = 32
      }
    }
  }
}

function Write-Utf8NoBom {
  param([string]$Path, [string]$Content)
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function Get-ResourceId {
  param([string]$ApiId, [string]$Region, [string]$Path)
  
  $all = aws apigateway get-resources --region $Region --rest-api-id $ApiId --output json 2>&1
  if ($LASTEXITCODE -ne 0) {
    Fail "Failed to list API Gateway resources: $all"
  }
  
  $items = ($all | ConvertFrom-Json).items
  $match = $items | Where-Object { $_.path -eq $Path }
  
  if ($match -and $match.id) {
    return $match.id
  }

  $paths = $items | Select-Object -ExpandProperty path
  Fail "Cannot resolve resourceId for '$Path'. Available paths: $($paths -join ', ')"
}

function Test-Invoke {
  param([string]$ApiId, [string]$Region, [string]$ResourceId, [string]$BodyFile)
  
  if (-not (Test-Path $BodyFile)) {
    Fail "Body file not found: $BodyFile"
  }
  
  Write-Host "Invoking DLT API (this may take 30-60s)..." -ForegroundColor Gray
  
  $contentTypeHeader = "Content-Type=application/json"

  $resp = aws apigateway test-invoke-method `
    --region $Region `
    --rest-api-id $ApiId `
    --resource-id $ResourceId `
    --http-method POST `
    --path-with-query-string $script:ApiResourcePath `
    --headers $contentTypeHeader `
    --body "file://$BodyFile" `
    --output json 2>&1
    
  if ($LASTEXITCODE -ne 0) { 
    Fail "test-invoke-method failed (exit code: $LASTEXITCODE): $resp" 
  }
  
  $parsed = $resp | ConvertFrom-Json
  if (-not $parsed) {
    Fail "Failed to parse AWS CLI response: $resp"
  }
  
  return $parsed
}

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  DLT Shopify Order Load Test Trigger" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# Validate inputs
$validScenarios = @('quick', 'normal', 'peak')
if ($Scenario -notin $validScenarios) {
  Fail "Invalid scenario '$Scenario'. Valid scenarios: $($validScenarios -join ', ')"
}

Require-Env @("LOADTEST_DLT_API","LOADTEST_SCRIPTS_BUCKET","LOADTEST_SHOPIFY_URL","LOADTEST_SHOPIFY_TOKEN")

# Constants
$script:ApiResourcePath = "/scenarios"
$Script = "load-test-k6.js"

# Resolve paths
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$localPath = Join-Path $scriptDir $Script

if (-not (Test-Path $localPath)) { 
  Fail "Script not found: $localPath" 
}

# Parse API endpoint
try {
  $api = Get-ApiParts -Url $env:LOADTEST_DLT_API
  $Region = $api.Region
  $ApiId = $api.ApiId
  $Stage = $api.Stage
} catch {
  Fail $_.Exception.Message
}

$Bucket = $env:LOADTEST_SCRIPTS_BUCKET
$ShopifyUrl = $env:LOADTEST_SHOPIFY_URL
$ShopifyToken = $env:LOADTEST_SHOPIFY_TOKEN

# Generate test ID (short format like UI)
$TestId = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 10 | ForEach-Object {[char]$_})
# S3 key - match UI path convention: public/test-scenarios/k6/{testId}.js
$S3Key  = "public/test-scenarios/k6/$TestId.js"

Write-Host "Configuration:"
Write-Host "  Script:       $Script"
Write-Host "  TestId:       $TestId"
Write-Host "  Scenario:     $Scenario"
Write-Host "  API Path:     $script:ApiResourcePath"
Write-Host "  Region:       $Region"
Write-Host "  API ID:       $ApiId"
Write-Host "  Stage:        $Stage"
Write-Host "  S3 Bucket:    $Bucket"
Write-Host "  S3 Key:       $S3Key`n"

# Debug: File information
Write-Host "[DEBUG] Local Script Information:" -ForegroundColor Gray
Write-Host "  Local Path:   $localPath" -ForegroundColor Gray
$fileSize = (Get-Item $localPath).Length
Write-Host "  File Size:    $fileSize bytes ($([math]::Round($fileSize/1KB, 2)) KB)" -ForegroundColor Gray
Write-Host ""

# Environment variables will be passed to k6 containers
Write-Host "[DEBUG] Environment Variables:" -ForegroundColor Gray
Write-Host "  SHOPIFY_URL:     $($ShopifyUrl.Substring(0, [Math]::Min(50, $ShopifyUrl.Length)))..." -ForegroundColor Gray
Write-Host "  SHOPIFY_TOKEN:   $($ShopifyToken.Substring(0, [Math]::Min(20, $ShopifyToken.Length)))... [REDACTED]" -ForegroundColor Gray
Write-Host "  SCENARIO:        $Scenario" -ForegroundColor Gray
if ($env:LOADTEST_SPECIAL_SKUS_RATE) {
  Write-Host "  SPECIAL_SKUS_RATE: $env:LOADTEST_SPECIAL_SKUS_RATE" -ForegroundColor Gray
}
Write-Host "  (Will be available in k6 script as __ENV.SHOPIFY_URL, __ENV.SHOPIFY_TOKEN, __ENV.SCENARIO, __ENV.SPECIAL_SKUS_RATE)" -ForegroundColor Gray
Write-Host ""

# 1) Upload artifact
Write-Host "[DEBUG] S3 Upload Details:" -ForegroundColor Gray
Write-Host "  Uploading to: s3://$Bucket/$S3Key" -ForegroundColor Gray
Write-Host ""

try {
  S3-Upload -LocalPath $localPath -Bucket $Bucket -Key $S3Key -Region $Region
  Write-Host "[SUCCESS] Upload complete: s3://$Bucket/$S3Key`n" -ForegroundColor Green
} catch {
  Write-Host "[ERROR] S3 upload failed: $_" -ForegroundColor Red
  Fail "S3 upload failed: $_"
}

# 2) Build payload (match DLT UI format + env vars for k6)
$payload = Build-Payload -TestId $TestId -Script $Script -Region $Region -ShopifyUrl $ShopifyUrl -ShopifyToken $ShopifyToken -Scenario $Scenario

$tmp = Join-Path $env:TEMP "dlt-shopify-orders-$($TestId).json"
try {
  $json = $payload | ConvertTo-Json -Depth 10
  Write-Utf8NoBom -Path $tmp -Content $json
} catch {
  Fail "Failed to create config file without BOM: $_"
}

Write-Host "[DEBUG] Payload:" -ForegroundColor Gray
Get-Content $tmp | Write-Host -ForegroundColor Gray
Write-Host ""

# 3) Resolve resource
Write-Host "[DEBUG] Resolving API Gateway resource..." -ForegroundColor Gray
Write-Host "  API ID:      $ApiId" -ForegroundColor Gray
Write-Host "  Region:      $Region" -ForegroundColor Gray
Write-Host "  Path:        $script:ApiResourcePath" -ForegroundColor Gray
Write-Host ""

try {
  $resourceId = Get-ResourceId -ApiId $ApiId -Region $Region -Path $script:ApiResourcePath
  Write-Host "[DEBUG] Resource ID resolved: $resourceId" -ForegroundColor Green
  Write-Host ""
} catch {
  Write-Host "[ERROR] Failed to get resource ID: $_" -ForegroundColor Red
  Fail "Failed to get resource ID: $_"
}

# 4) Invoke API
Write-Host "[DEBUG] Invoking API Gateway..." -ForegroundColor Gray
Write-Host "  Endpoint:    https://$ApiId.execute-api.$Region.amazonaws.com/$Stage$script:ApiResourcePath" -ForegroundColor Gray
Write-Host "  Method:      POST" -ForegroundColor Gray
Write-Host "  Body File:   $tmp" -ForegroundColor Gray
Write-Host ""

try {
  $response = Test-Invoke -ApiId $ApiId -Region $Region -ResourceId $resourceId -BodyFile $tmp
  Write-Host "[DEBUG] API invocation completed" -ForegroundColor Green
  Write-Host ""
} catch {
  Write-Host "[ERROR] API invocation failed. Cleaning up..." -ForegroundColor Yellow
  Remove-Item $tmp -Force -ErrorAction SilentlyContinue
  Fail $_ 
}

# 5) Parse response
Write-Host "[DEBUG] API Response:" -ForegroundColor Gray
Write-Host "  Status:      $($response.status)" -ForegroundColor Gray
Write-Host "  Status Code: $($response.statusCode)" -ForegroundColor Gray

if ($response.status -eq 200 -and $response.body) {
  try {
    $b = $response.body | ConvertFrom-Json -ErrorAction Stop
    $tid = $b.testId
    if (-not $tid) { $tid = $b.id }
    if (-not $tid) { $tid = $TestId }
    
    Write-Host "`n========================================" -ForegroundColor Green
    Write-Host "[SUCCESS] Load test started!" -ForegroundColor Green
    Write-Host "========================================`n" -ForegroundColor Green
    Write-Host "Test ID: $tid" -ForegroundColor Yellow
    
} catch {
    Write-Host "[WARNING] Submitted successfully, but cannot parse response body" -ForegroundColor Yellow
    Write-Host "[DEBUG] Raw response body:" -ForegroundColor Gray
    Write-Host $response.body -ForegroundColor Gray
  }
} else {
  Write-Host "`n========================================" -ForegroundColor Yellow
  Write-Host "[WARNING] API returned status $($response.status)" -ForegroundColor Yellow
  Write-Host "========================================`n" -ForegroundColor Yellow
  Write-Host "[DEBUG] Full response details:" -ForegroundColor Gray
  Write-Host "  Status:      $($response.status)" -ForegroundColor Gray
  Write-Host "  Status Code: $($response.statusCode)" -ForegroundColor Gray
  if ($response.headers) {
    Write-Host "  Headers:" -ForegroundColor Gray
    $response.headers.PSObject.Properties | ForEach-Object {
      Write-Host "    $($_.Name): $($_.Value)" -ForegroundColor Gray
    }
  }
  Write-Host "  Body:" -ForegroundColor Gray
  $response.body | Write-Host -ForegroundColor Gray
  Write-Host ""
  Write-Host "[DEBUG] Full JSON response:" -ForegroundColor Gray
  $response | ConvertTo-Json -Depth 10 | Write-Host -ForegroundColor Gray
}

# Cleanup
Remove-Item $tmp -Force -ErrorAction SilentlyContinue

Write-Host ""

