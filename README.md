# Distributed Load Testing for Shopify Orders

Load testing project for Shopify order creation using AWS DLT (Distributed Load Testing on AWS) and k6.

---

## 🚀 Quick Start

### Prerequisites

- AWS account with admin permissions
- AWS CLI installed and configured
- PowerShell 5.1+ or PowerShell Core 7+
- Docker Desktop (for local testing)

### Step 1: Deploy Infrastructure

```powershell
# Set deployment variables
$env:LOADTEST_ADMIN_NAME = "Admin123"
$env:LOADTEST_ADMIN_EMAIL = "your-email@example.com"

# Deploy
cd infra
.\deploy-loadtest.ps1
```

**Save the outputs:**
- API Endpoint
- S3 Bucket name
- Console URL

### Step 2: Set Environment Variables

```powershell
# From deploy output
$env:LOADTEST_DLT_API = "https://xxx.execute-api.region.amazonaws.com/prod"
$env:LOADTEST_SCRIPTS_BUCKET = "sample-loadtest-dlt-xxx"

# Shopify credentials
$env:LOADTEST_SHOPIFY_URL = "your-store.myshopify.com"
$env:LOADTEST_SHOPIFY_TOKEN = "shpat_xxxxx"
```

### Step 3: Run Test

**Distributed test (on AWS):**
```powershell
cd apps\shopify
.\trigger-dlt.ps1 -Scenario "normal"
```

**Local test (with Docker):**
```powershell
cd apps\shopify
.\run-local.ps1 -Scenario "quick"
```

### Step 4: View Results

- **DLT Console:** Use Console URL from deploy output
- **S3:** `aws s3 ls s3://$env:LOADTEST_SCRIPTS_BUCKET/results/`

---

## 📖 Scripts

### deploy-loadtest.ps1

Deploy DLT infrastructure to AWS.

```powershell
cd infra
.\deploy-loadtest.ps1
```

**Parameters:**
- `-Region` - AWS region (default: auto-detect)
- `-SkipConfirmation` - Skip confirmation prompts
- `-EnableXRay` - Enable X-Ray tracing (default: "true")

**Requires:** `LOADTEST_ADMIN_NAME`, `LOADTEST_ADMIN_EMAIL`

---

### trigger-dlt.ps1

Trigger distributed load test on AWS DLT.

```powershell
cd apps\shopify
.\trigger-dlt.ps1 -Scenario "normal"
```

**Parameters:**
- `-Scenario` - Test scenario: `quick` | `normal` | `peak` (default: "normal")

**Test Scenarios:**

| Scenario | Iterations | VUs | Duration |
|----------|------------|-----|----------|
| `quick` | 2 | 1 | 5 min |
| `normal` | 500 | 5 | 60 min |
| `peak` | 1000 | 10 | 30 min |

**Requires:**
- `LOADTEST_DLT_API`
- `LOADTEST_SCRIPTS_BUCKET`
- `LOADTEST_SHOPIFY_URL`
- `LOADTEST_SHOPIFY_TOKEN`

**Optional:**
- `LOADTEST_SPECIAL_SKUS_RATE` - Rate of orders with special SKUs (0-1, default: 0.01 = 1%)

---

### run-local.ps1

Run test locally using Docker.

```powershell
cd apps\shopify
.\run-local.ps1 -Scenario "quick"
```

**Parameters:**
- `-Scenario` - Test scenario: `quick` | `normal` | `peak` (default: "quick")

**Requires:**
- Docker Desktop running
- `LOADTEST_SHOPIFY_URL`
- `LOADTEST_SHOPIFY_TOKEN`

**Optional:**
- `LOADTEST_SPECIAL_SKUS_RATE` - Rate of orders with special SKUs (0-1, default: 0.01 = 1%)

---

### destroy-loadtest.ps1

Delete DLT infrastructure from AWS.

```powershell
cd infra
.\destroy-loadtest.ps1
```

**⚠️ Warning:** Make sure no tests are running before destroying.

---

## ⚙️ Environment Variables

### Deployment

```powershell
$env:LOADTEST_ADMIN_NAME = "Admin123"
$env:LOADTEST_ADMIN_EMAIL = "your-email@example.com"
```

### Shopify Order Creation Test

```powershell
# Required
$env:LOADTEST_DLT_API = "https://xxx.execute-api.region.amazonaws.com/prod"
$env:LOADTEST_SCRIPTS_BUCKET = "bucket-name"
$env:LOADTEST_SHOPIFY_URL = "your-store.myshopify.com"
$env:LOADTEST_SHOPIFY_TOKEN = "shpat_xxxxx"

# Optional
$env:LOADTEST_SPECIAL_SKUS_RATE = "0.01"  # 1% orders with special SKUs
```

---

## 🔍 Viewing Results

### DLT Console

1. Open Console URL from deploy output
2. Login with `LOADTEST_ADMIN_NAME` / password from email
3. View real-time metrics and final results

### S3 Results

```powershell
# List all test results
aws s3 ls s3://$env:LOADTEST_SCRIPTS_BUCKET/results/

# Download specific test results
aws s3 cp s3://$env:LOADTEST_SCRIPTS_BUCKET/results/{testId}/ ./results/ --recursive
```

### CloudWatch

Navigate to CloudWatch Console to view:
- API Gateway metrics (latency, errors, request count)
- Lambda functions (duration, throttles, concurrency)
- ECS tasks (CPU, memory usage)

---

## 🔧 Troubleshooting

### Verify Setup

```powershell
# Check environment variables
Get-ChildItem Env: | Where-Object { $_.Name -like "LOADTEST*" }

# Check AWS credentials
aws sts get-caller-identity

# Check DLT stack status
aws cloudformation describe-stacks --stack-name Sample-LoadTest
```

### Common Issues

**"Missing env vars" error:**
```powershell
# Set all required variables
$env:LOADTEST_DLT_API = "https://..."
$env:LOADTEST_SCRIPTS_BUCKET = "bucket-name"
$env:LOADTEST_SHOPIFY_URL = "your-store.myshopify.com"
$env:LOADTEST_SHOPIFY_TOKEN = "shpat_xxxxx"
```

**"401 Unauthorized" in test results:**
```powershell
# Get fresh Shopify access token
$env:LOADTEST_SHOPIFY_TOKEN = "shpat_xxxxx"
```

**"Upload failed" error:**
```powershell
# Check AWS credentials and S3 access
aws sts get-caller-identity
aws s3 ls s3://$env:LOADTEST_SCRIPTS_BUCKET/
```

---

## 📁 Project Structure

```
aka-int-load-test/
├── apps/
│   └── shopify/
│       ├── load-test-k6.js          # k6 test script
│       ├── trigger-dlt.ps1          # Trigger distributed test
│       └── run-local.ps1            # Run local test
├── infra/
│   ├── deploy-loadtest.ps1          # Deploy infrastructure
│   ├── destroy-loadtest.ps1         # Destroy infrastructure
│   └── distributed-load-testing-on-aws.template
└── README.md
```

---

## 📝 Notes

- All test configuration (scenarios, thresholds) is embedded in `load-test-k6.js`
- Test scenarios: `quick` (2 orders, 5 min), `normal` (500 orders, 60 min), `peak` (1000 orders, 30 min)
- Performance thresholds: P95 latency < 5s, error rate < 10%, success rate > 90%
