# deploy-loadtest.ps1 - Deploy DLT Load Testing Infrastructure
# Usage: .\deploy-loadtest.ps1 [-Region <REGION>] [-SkipConfirmation] [-EnableXRay <true|false>]

param(
    [string]$Region,
    [switch]$SkipConfirmation,
    [string]$EnableXRay = "true"
)

# Colors for output
$host.ui.RawUI.ForegroundColor = "White"

function Write-Info {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Blue
}

function Write-Success {
    param([string]$Message)
    Write-Host "[SUCCESS] $Message" -ForegroundColor Green
}

function Write-Warning {
    param([string]$Message)
    Write-Host "[WARNING] $Message" -ForegroundColor Yellow
}

function Write-Error {
    param([string]$Message)
    Write-Host "[ERROR] $Message" -ForegroundColor Red
}

function Write-Step {
    param([string]$Message)
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "$Message" -ForegroundColor Cyan
    Write-Host "========================================`n" -ForegroundColor Cyan
}

Write-Host "`n========================================" -ForegroundColor Magenta
Write-Host "  DLT Load Testing Infrastructure Deployment" -ForegroundColor Magenta
Write-Host "========================================`n" -ForegroundColor Magenta

# Step 1: Get AWS Region
Write-Step "Step 1: Get AWS Region"
if (-not $Region) {
    if ($env:AWS_REGION) {
        $Region = $env:AWS_REGION
        Write-Info "Using region from environment: $Region"
    } else {
        $Region = aws configure get region 2>$null
        if ($Region) {
            Write-Info "Using region from AWS config: $Region"
        } else {
            $Region = "us-east-1"
            Write-Warning "No region configured, using default: $Region"
        }
    }
} else {
    Write-Info "Using region from parameter: $Region"
}

# Step 2: Validate AWS Credentials
Write-Step "Step 2: Validate AWS Credentials"
Write-Info "Checking AWS credentials..."
$awsIdentity = aws sts get-caller-identity 2>$null | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to get AWS credentials. Please configure AWS credentials first."
    Write-Info "Run: aws configure"
    exit 1
}
Write-Success "AWS credentials validated"
Write-Info "Account: $($awsIdentity.Account)"
Write-Info "User/Role: $($awsIdentity.Arn)"

# Step 3: Validate Required Environment Variables
Write-Step "Step 3: Validate Environment Variables"

# Only validate deployment-related variables (AdminName, AdminEmail)
$requiredForDeploy = @(
    "LOADTEST_ADMIN_NAME",
    "LOADTEST_ADMIN_EMAIL"
)

$missingVars = @()
foreach ($var in $requiredForDeploy) {
    $value = Get-Item "env:$var" -ErrorAction SilentlyContinue
    if (-not $value -or [string]::IsNullOrEmpty($value.Value)) {
        $missingVars += $var
    }
}

if ($missingVars.Count -gt 0) {
    Write-Error "Missing required environment variables for deployment:"
    foreach ($var in $missingVars) {
        Write-Host "  - $var"
    }
    Write-Info "Please set these variables before running the script."
    Write-Info "Example:"
    Write-Info "  `$env:LOADTEST_ADMIN_NAME = 'your-name'"
    Write-Info "  `$env:LOADTEST_ADMIN_EMAIL = 'your-email@example.com'"
    exit 1
}

Write-Success "Required environment variables for deployment are set"

# Display deployment variables
Write-Host ""
Write-Host "Deployment Configuration:" -ForegroundColor Cyan
foreach ($var in $requiredForDeploy) {
    $envValue = Get-Item "env:$var" -ErrorAction SilentlyContinue
    $value = if ($envValue) { $envValue.Value } else { "NOT SET" }
    Write-Host "  $var`: $value"
}

# Check optional testing variables
$optionalVars = @("LOADTEST_TARGET_URL", "LOADTEST_AUTH_TOKEN")
$hasOptional = $false
Write-Host ""
Write-Host "Testing Configuration:" -ForegroundColor Yellow
foreach ($var in $optionalVars) {
    $envValue = Get-Item "env:$var" -ErrorAction SilentlyContinue
    if ($envValue -and -not [string]::IsNullOrEmpty($envValue.Value)) {
        Write-Host " $var`: Set"
        $hasOptional = $true
    } else {
        Write-Host " $var`: Not set (will need to set before running tests)"
    }
}

if (-not $hasOptional) {
    Write-Warning "Testing variables not set - you'll need to set them before running load tests"
    Write-Info "Set them later with:"
    Write-Info "  `$env:LOADTEST_TARGET_URL = 'https://your-api.com'"
    Write-Info "  `$env:LOADTEST_AUTH_TOKEN = 'your-jwt-token'"
}
Write-Host ""

# Step 4: Deploy DLT Stack
Write-Step "Step 4: Deploy DLT Stack"
$stackName = "Sample-LoadTest"

# Find template file (works from any directory)
# Script and template both live in infra/
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$templateFile = Join-Path $scriptDir "distributed-load-testing-on-aws.template"

if (-not (Test-Path $templateFile)) {
    Write-Error "Template file not found: $templateFile"
    Write-Info "Make sure you're running this script from the correct directory"
    exit 1
}

Write-Info "Using template: $templateFile"

# Check if stack exists
Write-Info "Checking if stack exists..."
$stackExists = aws cloudformation describe-stacks --stack-name $stackName --region $Region 2>$null
$isUpdate = $LASTEXITCODE -eq 0

if ($isUpdate) {
    $stackStatus = ($stackExists | ConvertFrom-Json).Stacks[0].StackStatus
    Write-Warning "Stack '$stackName' exists with status: $stackStatus"

    if (-not $SkipConfirmation) {
        $confirm = Read-Host "Do you want to update the stack? (yes/no)"
        if ($confirm -ne "yes") {
            Write-Info "Deployment cancelled by user"
            exit 0
        }
    }
}

# Create template bucket (fixed name for easy management)
Write-Info "Creating template bucket for CloudFormation..."
$templateBucket = "aka-loadtest-cfn-template"

# Check if bucket exists
$bucketExists = aws s3 ls "s3://$templateBucket" 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Info "Template bucket already exists: $templateBucket"
} else {
    aws s3 mb s3://$templateBucket --region $Region
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to create template bucket"
        exit 1
    }
    Write-Success "Created template bucket: $templateBucket"
}

# Upload template
Write-Info "Uploading template to S3..."
aws s3 cp "$templateFile" s3://$templateBucket/distributed-load-testing-on-aws.template
if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to upload template"
    exit 1
}
Write-Success "Template uploaded"

# Deploy/Update stack
Write-Info "Deployment parameters:"
Write-Info "  AdminName: '$env:LOADTEST_ADMIN_NAME'"
Write-Info "  AdminEmail: '$env:LOADTEST_ADMIN_EMAIL'"

if ($isUpdate) {
    Write-Info "Updating stack (this takes 5-10 minutes)..."
    aws cloudformation update-stack `
        --stack-name $stackName `
        --template-url "https://s3.$Region.amazonaws.com/$templateBucket/distributed-load-testing-on-aws.template" `
        --parameters ParameterKey=AdminName,ParameterValue="$env:LOADTEST_ADMIN_NAME" ParameterKey=AdminEmail,ParameterValue="$env:LOADTEST_ADMIN_EMAIL" `
        --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM `
        --region $Region

    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to update stack"
        exit 1
    }

    Write-Info "Waiting for stack update to complete..."
    aws cloudformation wait stack-update-complete --stack-name $stackName --region $Region
} else {
    Write-Info "Creating stack (this takes 10-15 minutes)..."
    aws cloudformation create-stack `
        --stack-name $stackName `
        --template-url "https://s3.$Region.amazonaws.com/$templateBucket/distributed-load-testing-on-aws.template" `
        --parameters ParameterKey=AdminName,ParameterValue="$env:LOADTEST_ADMIN_NAME" ParameterKey=AdminEmail,ParameterValue="$env:LOADTEST_ADMIN_EMAIL" `
        --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM `
        --region $Region

    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to create stack"
        exit 1
    }

    Write-Info "Waiting for stack creation to complete..."
    aws cloudformation wait stack-create-complete --stack-name $stackName --region $Region
}

if ($LASTEXITCODE -eq 0) {
    Write-Success "Stack deployment completed successfully!"
} else {
    Write-Error "Stack deployment failed"
    exit 1
}

# Step 5: Get Stack Outputs
Write-Step "Step 5: Get Stack Outputs"
Write-Info "Retrieving stack outputs..."

$stackOutputs = aws cloudformation describe-stacks `
    --stack-name $stackName `
    --region $Region `
    --query 'Stacks[0].Outputs' `
    --output json | ConvertFrom-Json

$apiEndpoint = ($stackOutputs | Where-Object { $_.OutputKey -eq "DLTApiEndpointD98B09AC" }).OutputValue
$scenariosBucket = ($stackOutputs | Where-Object { $_.OutputKey -eq "ScenariosBucket" }).OutputValue
$consoleUrl = ($stackOutputs | Where-Object { $_.OutputKey -eq "ConsoleURL" }).OutputValue

# Set environment variables for scripts
$env:LOADTEST_DLT_API = $apiEndpoint
$env:LOADTEST_SCRIPTS_BUCKET = $scenariosBucket

# Final Summary
Write-Host "`n"
Write-Host "========================================" -ForegroundColor Green
Write-Host "  DEPLOYMENT SUMMARY" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""

Write-Success "Stack Deployment: COMPLETED"
Write-Host ""
Write-Host "Console Access:" -ForegroundColor Yellow
Write-Host "  URL: $consoleUrl"
Write-Host "  Username: $env:LOADTEST_ADMIN_NAME"
Write-Host "  Password: Check your email at $env:LOADTEST_ADMIN_EMAIL"
Write-Host ""
Write-Host "Configuration:" -ForegroundColor Cyan
Write-Host "  Stack Name: $stackName"
Write-Host "  Region: $Region"
Write-Host ""
Write-Host "DLT Outputs:" -ForegroundColor Cyan
Write-Host "  API Endpoint: $apiEndpoint"
Write-Host "  S3 Bucket: $scenariosBucket"
Write-Host "  Console URL: $consoleUrl"
Write-Host ""
Write-Host "Environment Variables (set for this session):" -ForegroundColor Cyan
Write-Host "  `$env:LOADTEST_DLT_API = '$apiEndpoint'"
Write-Host "  `$env:LOADTEST_SCRIPTS_BUCKET = '$scenariosBucket'"
Write-Host ""
Write-Host "Next Steps:" -ForegroundColor Yellow
Write-Host "  1. Set environment variables (if in new terminal):"
Write-Host "     `$env:LOADTEST_DLT_API = '$apiEndpoint'"
Write-Host "     `$env:LOADTEST_SCRIPTS_BUCKET = '$scenariosBucket'"
Write-Host "     `$env:LOADTEST_TARGET_URL = 'https://your-api.com'"
Write-Host "     `$env:LOADTEST_AUTH_TOKEN = 'your-jwt-token'"
Write-Host ""
Write-Host "  2. Run load test:"
Write-Host "     .\start-test.ps1 -Script 'load-test-k6.js'"
Write-Host ""
Write-Host "  3. View console:"
Write-Host "     $consoleUrl"
Write-Host ""

# Step 6: Enable X-Ray Tracing (Post-Deploy)
Write-Step "Step 6: Enable X-Ray Tracing (Post-Deploy)"
if ($EnableXRay -eq "true") {
    Write-Host "[Post-Deploy] Enabling AWS X-Ray tracing for Lambda functions..." -ForegroundColor Cyan

    $prefix = "$stackName-DLTLambdaFunction"
    Write-Info "Searching for Lambda functions with prefix: $prefix"

    $functionsResult = aws lambda list-functions `
        --region $Region `
        --query "Functions[?starts_with(FunctionName, '$prefix')].FunctionName" `
        --output text `
        2>&1

    if ($LASTEXITCODE -eq 0 -and $functionsResult -and $functionsResult.Trim()) {
        $functions = $functionsResult.Trim() -split '\s+'
        $enabledCount = 0

        foreach ($fn in $functions) {
            if ($fn -and $fn.Trim()) {
                $fnName = $fn.Trim()
                Write-Info "  Enabling tracing for: $fnName"

                $updateResult = aws lambda update-function-configuration `
                    --function-name $fnName `
                    --tracing-config Mode=Active `
                    --region $Region `
                    2>&1

                if ($LASTEXITCODE -eq 0) {
                    $enabledCount++
                    Write-Success "X-Ray tracing enabled for: $fnName"
                } else {
                    Write-Warning "Failed to enable X-Ray for: $fnName"
                    Write-Info "     Error: $updateResult"
                }
            }
        }

        if ($enabledCount -gt 0) {
            Write-Success "X-Ray tracing enabled for $enabledCount Lambda function(s) with prefix $prefix"
        } else {
            Write-Warning "No Lambda functions were successfully updated"
        }
    } else {
        Write-Warning "No Lambda functions found with prefix $prefix"
        if ($LASTEXITCODE -ne 0) {
            Write-Info "AWS CLI error: $functionsResult"
        }
    }

    Write-Success "X-Ray tracing setup completed."
} else {
    Write-Host "[Post-Deploy] EnableXRay=false - skipping X-Ray setup." -ForegroundColor Yellow
}

Write-Host ""

