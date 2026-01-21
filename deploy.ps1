# Streaming Agent AWS Deployment Script
# Run this script from the streaming_agent_langchain directory

param(
    [string]$Region = "us-east-1",
    [string]$AccountId = "125975759762"
)

$ErrorActionPreference = "Stop"

# Configuration
$APP_NAME = "streaming-agent"
$ECR_REPO = "$APP_NAME-api"
$LAMBDA_FUNCTION = "$APP_NAME-api"
$S3_BUCKET = "$APP_NAME-frontend-$AccountId"
$LAMBDA_ROLE = "$APP_NAME-lambda-role"

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Streaming Agent AWS Deployment" -ForegroundColor Cyan
Write-Host "Region: $Region" -ForegroundColor Cyan
Write-Host "Account: $AccountId" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# Step 1: Store secrets in SSM Parameter Store
Write-Host "`n[1/8] Storing secrets in SSM Parameter Store..." -ForegroundColor Yellow

$envFile = Get-Content ".env" | Where-Object { $_ -match "=" }
foreach ($line in $envFile) {
    $parts = $line -split "=", 2
    $key = $parts[0].Trim()
    $value = $parts[1].Trim()
    
    if ($key -in @("OPENAI_API_KEY", "SERPAPI_API_KEY")) {
        Write-Host "  Storing /streaming-agent/$key..."
        aws ssm put-parameter `
            --name "/streaming-agent/$key" `
            --value "$value" `
            --type "SecureString" `
            --overwrite `
            --region $Region 2>$null
    }
}
Write-Host "  Secrets stored successfully!" -ForegroundColor Green

# Step 2: Create ECR Repository
Write-Host "`n[2/8] Creating ECR Repository..." -ForegroundColor Yellow
$ecrExists = aws ecr describe-repositories --repository-names $ECR_REPO --region $Region 2>$null
if (-not $ecrExists) {
    aws ecr create-repository --repository-name $ECR_REPO --region $Region --output json
    Write-Host "  ECR Repository created!" -ForegroundColor Green
} else {
    Write-Host "  ECR Repository already exists." -ForegroundColor Green
}

# Step 3: Build and push Docker image
Write-Host "`n[3/8] Building and pushing Docker image..." -ForegroundColor Yellow
Push-Location "application/api"

# Login to ECR
aws ecr get-login-password --region $Region | docker login --username AWS --password-stdin "$AccountId.dkr.ecr.$Region.amazonaws.com"

# Build image
$imageUri = "$AccountId.dkr.ecr.$Region.amazonaws.com/${ECR_REPO}:latest"
docker build -t $ECR_REPO .
docker tag "${ECR_REPO}:latest" $imageUri

# Push image
docker push $imageUri
Write-Host "  Docker image pushed: $imageUri" -ForegroundColor Green
Pop-Location

# Step 4: Create Lambda execution role
Write-Host "`n[4/8] Creating Lambda execution role..." -ForegroundColor Yellow

$trustPolicy = @"
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
"@

$roleExists = aws iam get-role --role-name $LAMBDA_ROLE 2>$null
if (-not $roleExists) {
    $trustPolicy | Out-File -FilePath "trust-policy.json" -Encoding utf8
    aws iam create-role `
        --role-name $LAMBDA_ROLE `
        --assume-role-policy-document file://trust-policy.json `
        --output json
    
    # Attach policies
    aws iam attach-role-policy --role-name $LAMBDA_ROLE --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
    aws iam attach-role-policy --role-name $LAMBDA_ROLE --policy-arn arn:aws:iam::aws:policy/AmazonSSMReadOnlyAccess
    
    Remove-Item "trust-policy.json"
    Write-Host "  Lambda role created!" -ForegroundColor Green
    Write-Host "  Waiting 10 seconds for role propagation..." -ForegroundColor Yellow
    Start-Sleep -Seconds 10
} else {
    Write-Host "  Lambda role already exists." -ForegroundColor Green
}

$roleArn = "arn:aws:iam::${AccountId}:role/$LAMBDA_ROLE"

# Step 5: Create/Update Lambda function
Write-Host "`n[5/8] Creating Lambda function..." -ForegroundColor Yellow

$lambdaExists = aws lambda get-function --function-name $LAMBDA_FUNCTION --region $Region 2>$null
if (-not $lambdaExists) {
    aws lambda create-function `
        --function-name $LAMBDA_FUNCTION `
        --package-type Image `
        --code "ImageUri=$imageUri" `
        --role $roleArn `
        --timeout 300 `
        --memory-size 1024 `
        --region $Region `
        --output json
    
    Write-Host "  Lambda function created!" -ForegroundColor Green
    Start-Sleep -Seconds 5
} else {
    aws lambda update-function-code `
        --function-name $LAMBDA_FUNCTION `
        --image-uri $imageUri `
        --region $Region `
        --output json
    Write-Host "  Lambda function updated!" -ForegroundColor Green
    Start-Sleep -Seconds 5
}

# Step 6: Create Lambda Function URL
Write-Host "`n[6/8] Creating Lambda Function URL..." -ForegroundColor Yellow

$funcUrlExists = aws lambda get-function-url-config --function-name $LAMBDA_FUNCTION --region $Region 2>$null
if (-not $funcUrlExists) {
    $funcUrlResult = aws lambda create-function-url-config `
        --function-name $LAMBDA_FUNCTION `
        --auth-type NONE `
        --cors "AllowOrigins=*,AllowMethods=*,AllowHeaders=*" `
        --invoke-mode RESPONSE_STREAM `
        --region $Region `
        --output json | ConvertFrom-Json
    
    # Add permission for public access
    aws lambda add-permission `
        --function-name $LAMBDA_FUNCTION `
        --statement-id FunctionURLAllowPublicAccess `
        --action lambda:InvokeFunctionUrl `
        --principal "*" `
        --function-url-auth-type NONE `
        --region $Region 2>$null
    
    $lambdaUrl = $funcUrlResult.FunctionUrl
} else {
    $funcUrlResult = $funcUrlExists | ConvertFrom-Json
    $lambdaUrl = $funcUrlResult.FunctionUrl
}

Write-Host "  Lambda URL: $lambdaUrl" -ForegroundColor Green

# Step 7: Build and deploy frontend
Write-Host "`n[7/8] Building and deploying frontend to S3..." -ForegroundColor Yellow
Push-Location "application/app"

# Update .env.production with actual Lambda URL
$lambdaUrlClean = $lambdaUrl.TrimEnd('/')
"NEXT_PUBLIC_API_URL=$lambdaUrlClean" | Out-File -FilePath ".env.production" -Encoding utf8

# Build Next.js static export
npm run build

# Create S3 bucket
$bucketExists = aws s3api head-bucket --bucket $S3_BUCKET 2>$null
if (-not $?) {
    aws s3api create-bucket --bucket $S3_BUCKET --region $Region
}

# Configure bucket for static website hosting
aws s3api put-public-access-block `
    --bucket $S3_BUCKET `
    --public-access-block-configuration "BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false"

$bucketPolicy = @"
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "PublicReadGetObject",
            "Effect": "Allow",
            "Principal": "*",
            "Action": "s3:GetObject",
            "Resource": "arn:aws:s3:::$S3_BUCKET/*"
        }
    ]
}
"@
$bucketPolicy | Out-File -FilePath "bucket-policy.json" -Encoding utf8
aws s3api put-bucket-policy --bucket $S3_BUCKET --policy file://bucket-policy.json
Remove-Item "bucket-policy.json"

aws s3 website "s3://$S3_BUCKET" --index-document index.html --error-document index.html

# Upload files
aws s3 sync out/ "s3://$S3_BUCKET/" --delete

Pop-Location
Write-Host "  Frontend deployed to S3!" -ForegroundColor Green

# Step 8: Output results
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "DEPLOYMENT COMPLETE!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan

$s3WebsiteUrl = "http://$S3_BUCKET.s3-website-$Region.amazonaws.com"

Write-Host "`nEndpoints:" -ForegroundColor Yellow
Write-Host "  Frontend (S3):  $s3WebsiteUrl" -ForegroundColor White
Write-Host "  Backend (Lambda): $lambdaUrl" -ForegroundColor White
Write-Host "`nTest the API:" -ForegroundColor Yellow
Write-Host "  curl -X POST '${lambdaUrl}invoke?content=hello'" -ForegroundColor White
Write-Host "`n"
