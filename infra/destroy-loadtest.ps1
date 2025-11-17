# destroy-loadtest.ps1 - Destroy DLT Load Testing Stack
# Usage: .\destroy-loadtest.ps1 [-StackName <NAME>] [-Region <REGION>] [-SkipConfirmation]

param(
    [string]$StackName = "Sample-LoadTest",
    [string]$Region,
    [switch]$SkipConfirmation
)

# Get AWS region: from parameter, env var, AWS config, or default to us-east-1
if (-not $Region) {
    if ($env:AWS_REGION) {
        $Region = $env:AWS_REGION
    } else {
        $configRegion = aws configure get region 2>$null
        if ($configRegion) {
            $Region = $configRegion
        } else {
            $Region = "us-east-1"
        }
    }
}

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

Write-Info "Destroying DLT Load Testing Stack"
Write-Info "Stack Name: $StackName"
Write-Info "Region: $Region"

# Confirm deletion (unless skipped)
if (-not $SkipConfirmation) {
    Write-Warning "This will delete the entire DLT infrastructure including:"
    Write-Warning "  - VPC and all networking components"
    Write-Warning "  - ECS Cluster and Tasks"
    Write-Warning "  - Lambda Functions"
    Write-Warning "  - API Gateway"
    Write-Warning "  - S3 Buckets"
    Write-Warning "  - CloudWatch Logs"
    Write-Warning "  - IAM Roles and Policies"
    Write-Warning ""
    Write-Info "The script will also cleanup any orphaned VPCs if CloudFormation fails to delete them"
    Write-Warning ""
    $confirm = Read-Host "Are you sure you want to delete the stack? Type 'yes' to confirm"
    
    if ($confirm -ne "yes") {
        Write-Info "Deletion cancelled by user"
        exit 0
    }
}

# Check if stack exists
Write-Info "Checking if stack exists..."
$stackCheck = aws cloudformation describe-stacks `
    --stack-name $StackName `
    --region $Region `
    2>&1

if ($LASTEXITCODE -ne 0) {
    $errorMessage = $stackCheck -join "`n"
    if ($errorMessage -match "does not exist") {
        Write-Warning "Stack '$StackName' does not exist in region '$Region'"
        Write-Info "Nothing to delete. Exiting."
        exit 0
    } else {
        Write-Error "Failed to check stack status: $errorMessage"
        exit 1
    }
}

Write-Success "Stack found"

# Display stack details
try {
    $stackJson = $stackCheck | ConvertFrom-Json
    $stackStatus = $stackJson.Stacks[0].StackStatus
    Write-Info "Current Stack Status: $stackStatus"
} catch {
    Write-Warning "Could not parse stack details"
}

# Check for running tests (optional)
Write-Info "Checking stack outputs..."
try {
    $stackOutputs = aws cloudformation describe-stacks `
        --stack-name $StackName `
        --region $Region `
        --query 'Stacks[0].Outputs' `
        --output json `
        2>&1
    
    if ($LASTEXITCODE -eq 0) {
        $outputs = $stackOutputs | ConvertFrom-Json
        $apiEndpoint = ($outputs | Where-Object { $_.OutputKey -eq "DLTApiEndpointD98B09AC" }).OutputValue
        
        if ($apiEndpoint) {
            Write-Info "DLT API Endpoint: $apiEndpoint"
            Write-Warning "Make sure no load tests are currently running before deletion"
        }
    }
} catch {
    Write-Warning "Could not retrieve stack outputs"
}

# Delete the stack
Write-Info "Initiating stack deletion..."
$deleteResult = aws cloudformation delete-stack `
    --stack-name $StackName `
    --region $Region `
    2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to initiate stack deletion"
    $deleteResult | ForEach-Object { Write-Host $_ -ForegroundColor Red }
    exit 1
}

Write-Success "Stack deletion initiated"

# Wait for deletion to complete
Write-Info "Waiting for stack deletion to complete (this may take 10-15 minutes)..."
Write-Info "You can monitor progress in AWS Console: https://console.aws.amazon.com/cloudformation"

$waitResult = aws cloudformation wait stack-delete-complete `
    --stack-name $StackName `
    --region $Region `
    2>&1

if ($LASTEXITCODE -eq 0) {
    Write-Success "Stack deletion completed successfully!"
} else {
    Write-Warning "Stack deletion may still be in progress or timed out"
    Write-Info "Check CloudFormation console for details: https://$Region.console.aws.amazon.com/cloudformation"
    Write-Info "Note: Some resources may take additional time to fully delete"
}

# Clean up template bucket (for CloudFormation template storage)
Write-Info "Cleaning up template S3 bucket..."
try {
    $templateBucket = "aka-loadtest-cfn-template"
    
    # Check if bucket exists
    $bucketCheck = aws s3 ls "s3://$templateBucket" 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Info "Found template bucket: $templateBucket"
        
        # First, delete all objects
        Write-Info "Deleting objects from template bucket..."
        aws s3 rm "s3://$templateBucket" --recursive 2>&1 | Out-Null
        
        # Then delete the bucket
        Write-Info "Deleting template bucket..."
        aws s3 rb "s3://$templateBucket" 2>&1 | Out-Null
        
        if ($LASTEXITCODE -eq 0) {
            Write-Success "Deleted template bucket: $templateBucket"
        } else {
            Write-Warning "Could not delete bucket (may have objects with versioning)"
        }
    } else {
        Write-Info "Template bucket not found: $templateBucket (already cleaned up or doesn't exist)"
    }
} catch {
    Write-Warning "Could not clean up template bucket (this is optional)"
}

# Verify and cleanup VPCs
Write-Info "Verifying VPCs cleanup..."
$vpcFilters = "Name=tag:aws:cloudformation:stack-name,Values=$StackName"
$remainingVpcs = aws ec2 describe-vpcs `
    --filters $vpcFilters `
    --region $Region `
    --query "Vpcs[*].VpcId" `
    --output json 2>$null

if ($LASTEXITCODE -eq 0 -and $remainingVpcs) {
    $vpcsArray = $remainingVpcs | ConvertFrom-Json
    
    if ($vpcsArray -and $vpcsArray.Count -gt 0) {
        Write-Warning "Found $($vpcsArray.Count) orphaned VPC(s) from stack: $StackName"
        Write-Host "VPC IDs: $($vpcsArray -join ', ')" -ForegroundColor Yellow
        Write-Host ""
        
        # Auto cleanup orphaned VPCs
        Write-Info "Cleaning up orphaned VPCs..."
        
        foreach ($vpcId in $vpcsArray) {
            Write-Info "Processing VPC: $vpcId"
            
            # Step 1: Delete VPC Endpoints
            $endpoints = aws ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=$vpcId" --region $Region --query "VpcEndpoints[*].VpcEndpointId" --output json 2>$null | ConvertFrom-Json
            foreach ($endpoint in $endpoints) {
                aws ec2 delete-vpc-endpoints --vpc-endpoint-ids $endpoint --region $Region 2>$null | Out-Null
                Write-Info "  Deleted VPC Endpoint: $endpoint"
            }
            
            # Wait for VPC Endpoint ENIs cleanup
            if ($endpoints -and $endpoints.Count -gt 0) {
                Write-Info "  Waiting 10 seconds for VPC Endpoint ENIs cleanup..."
                Start-Sleep -Seconds 10
            }
            
            # Step 2: Delete NAT Gateways (and wait for completion - they create ENIs in subnets)
            $natGws = aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$vpcId" --region $Region --query "NatGateways[*].NatGatewayId" --output json 2>$null | ConvertFrom-Json
            if ($natGws -and $natGws.Count -gt 0) {
                Write-Info "  Deleting NAT Gateways (this may take a few minutes)..."
                foreach ($natGw in $natGws) {
                    $natState = aws ec2 describe-nat-gateways --nat-gateway-ids $natGw --region $Region --query "NatGateways[0].State" --output text 2>$null
                    if ($natState -eq "available") {
                        aws ec2 delete-nat-gateway --nat-gateway-id $natGw --region $Region 2>$null | Out-Null
                        Write-Info "    Initiated deletion of NAT Gateway: $natGw"
                    }
                }
                
                # Wait for NAT Gateways to be deleted (max 5 minutes)
                $maxWait = 30
                $waited = 0
                $allDeleted = $false
                while ($waited -lt $maxWait -and -not $allDeleted) {
                    Start-Sleep -Seconds 10
                    $waited++
                    $remainingNatGws = aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$vpcId" --region $Region --query "NatGateways[?State!='deleted'].NatGatewayId" --output json 2>$null | ConvertFrom-Json
                    if (-not $remainingNatGws -or $remainingNatGws.Count -eq 0) {
                        $allDeleted = $true
                        Write-Info "    All NAT Gateways deleted"
                    } else {
                        Write-Info "    Waiting for NAT Gateways to be deleted... ($waited/$maxWait)"
                    }
                }
                if (-not $allDeleted) {
                    Write-Warning "    NAT Gateways may still be deleting, continuing anyway..."
                }
            }
            
            # Step 3: Disassociate Route Tables from Subnets (MUST be done before deleting subnets)
            Write-Info "  Disassociating route tables from subnets..."
            $subnets = aws ec2 describe-subnets --filters "Name=vpc-id,Values=$vpcId" --region $Region --query "Subnets[*].SubnetId" --output json 2>$null | ConvertFrom-Json
            $routeTablesJson = aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$vpcId" --region $Region --output json 2>$null
            
            if ($routeTablesJson) {
                try {
                    $routeTables = $routeTablesJson | ConvertFrom-Json
                    if ($routeTables.RouteTables) {
                        foreach ($rt in $routeTables.RouteTables) {
                            if ($rt.Associations) {
                                foreach ($association in $rt.Associations) {
                                    if ($association.SubnetId -and $association.RouteTableAssociationId -and -not $association.Main) {
                                        $disassocResult = aws ec2 disassociate-route-table --association-id $association.RouteTableAssociationId --region $Region 2>&1
                                        if ($LASTEXITCODE -eq 0) {
                                            Write-Info "    Disassociated route table $($rt.RouteTableId) from subnet $($association.SubnetId)"
                                        }
                                    }
                                }
                            }
                        }
                    }
                } catch {
                    Write-Warning "    Could not parse route tables, skipping disassociation"
                }
            }
            
            # Step 4: Delete ENIs in subnets (if any remain)
            Write-Info "  Checking for remaining ENIs in subnets..."
            if ($subnets) {
                foreach ($subnet in $subnets) {
                    $enis = aws ec2 describe-network-interfaces --filters "Name=subnet-id,Values=$subnet" --region $Region --query "NetworkInterfaces[*].NetworkInterfaceId" --output json 2>$null | ConvertFrom-Json
                    if ($enis -and $enis.Count -gt 0) {
                        foreach ($eni in $enis) {
                            # Try to detach first
                            $eniDetail = aws ec2 describe-network-interfaces --network-interface-ids $eni --region $Region --query "NetworkInterfaces[0]" --output json 2>$null | ConvertFrom-Json
                            if ($eniDetail -and $eniDetail.Attachment) {
                                aws ec2 detach-network-interface --attachment-id $eniDetail.Attachment.AttachmentId --force --region $Region 2>$null | Out-Null
                                Start-Sleep -Seconds 2
                            }
                            # Then delete
                            aws ec2 delete-network-interface --network-interface-id $eni --region $Region 2>$null | Out-Null
                            Write-Info "    Deleted ENI: $eni from subnet: $subnet"
                        }
                        Start-Sleep -Seconds 5
                    }
                }
            }
            
            # Step 5: Delete Internet Gateways
            $igws = aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$vpcId" --region $Region --query "InternetGateways[*].InternetGatewayId" --output json 2>$null | ConvertFrom-Json
            foreach ($igw in $igws) {
                aws ec2 detach-internet-gateway --internet-gateway-id $igw --vpc-id $vpcId --region $Region 2>$null | Out-Null
                aws ec2 delete-internet-gateway --internet-gateway-id $igw --region $Region 2>$null | Out-Null
                Write-Info "  Deleted Internet Gateway: $igw"
            }
            
            # Step 6: Delete Subnets (now safe - dependencies removed)
            if ($subnets) {
                Write-Info "  Deleting subnets..."
                foreach ($subnet in $subnets) {
                    $deleteSubnetResult = aws ec2 delete-subnet --subnet-id $subnet --region $Region 2>&1
                    if ($LASTEXITCODE -eq 0) {
                        Write-Success "    Deleted Subnet: $subnet"
                    } else {
                        Write-Warning "    Could not delete Subnet: $subnet - $deleteSubnetResult"
                    }
                }
            }
            
            # Step 7: Delete Route Tables (non-main only)
            $routeTables = aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$vpcId" --region $Region --query "RouteTables[?Associations[0].Main==``false``].RouteTableId" --output json 2>$null | ConvertFrom-Json
            foreach ($rt in $routeTables) {
                aws ec2 delete-route-table --route-table-id $rt --region $Region 2>$null | Out-Null
                Write-Info "  Deleted Route Table: $rt"
            }
            
            # Step 8: Delete Security Groups
            $sgs = aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$vpcId" --region $Region --query "SecurityGroups[?GroupName!='default'].GroupId" --output json 2>$null | ConvertFrom-Json
            foreach ($sg in $sgs) {
                aws ec2 delete-security-group --group-id $sg --region $Region 2>$null | Out-Null
                Write-Info "  Deleted Security Group: $sg"
            }
            
            # Step 9: Delete Network ACLs
            $acls = aws ec2 describe-network-acls --filters "Name=vpc-id,Values=$vpcId" --region $Region --query "NetworkAcls[?IsDefault==``false``].NetworkAclId" --output json 2>$null | ConvertFrom-Json
            foreach ($acl in $acls) {
                aws ec2 delete-network-acl --network-acl-id $acl --region $Region 2>$null | Out-Null
                Write-Info "  Deleted Network ACL: $acl"
            }
            
            # Step 10: Delete VPC
            Start-Sleep -Seconds 2
            $deleteVpcResult = aws ec2 delete-vpc --vpc-id $vpcId --region $Region 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Success "  VPC deleted: $vpcId"
            } else {
                Write-Warning "  Could not delete VPC: $vpcId (may have remaining dependencies)"
                Write-Info "    Error: $deleteVpcResult"
            }
        }
        Write-Success "VPCs cleanup completed"
    } else {
        Write-Success "No orphaned VPCs found - all cleaned up by CloudFormation"
    }
} else {
    Write-Success "No orphaned VPCs found - all cleaned up by CloudFormation"
}

# Final summary
Write-Host ""
Write-Success "Load testing infrastructure has been destroyed"
Write-Info "Summary:"
Write-Info "  - Stack Name: $StackName"
Write-Info "  - Region: $Region"
Write-Info "  - Status: DELETED"
Write-Info "  - VPCs: CLEANED UP"
Write-Host ""
