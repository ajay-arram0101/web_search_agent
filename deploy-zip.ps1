# Streaming Agent AWS Deployment Script (ZIP-based - No Docker Required)
# Run this script from the streaming_agent_langchain directory

param(
    [string]$Region = "us-east-1",
    [string]$AccountId = "125975759762"
)

$ErrorActionPreference = "Stop"

# Configuration
$APP_NAME = "streaming-agent"
$LAMBDA_FUNCTION = "$APP_NAME-api"
$S3_BUCKET = "$APP_NAME-frontend-$AccountId"
$LAMBDA_ROLE = "$APP_NAME-lambda-role"

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Streaming Agent AWS Deployment (ZIP)" -ForegroundColor Cyan
Write-Host "Region: $Region" -ForegroundColor Cyan
Write-Host "Account: $AccountId" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# Step 1: Store secrets in SSM Parameter Store
Write-Host "`n[1/7] Storing secrets in SSM Parameter Store..." -ForegroundColor Yellow

$envContent = Get-Content ".env" -Raw
$lines = $envContent -split "`n"
foreach ($line in $lines) {
    if ($line -match "^(OPENAI_API_KEY|SERPAPI_API_KEY)=(.+)$") {
        $key = $matches[1]
        $value = $matches[2].Trim()
        Write-Host "  Storing /streaming-agent/$key..."
        aws ssm put-parameter --name "/streaming-agent/$key" --value $value --type "SecureString" --overwrite --region $Region 2>$null | Out-Null
    }
}
Write-Host "  Secrets stored successfully!" -ForegroundColor Green

# Step 2: Create Lambda Layer with dependencies
Write-Host "`n[2/7] Creating Lambda Layer with dependencies..." -ForegroundColor Yellow

$layerDir = "lambda-layer"
$pythonDir = "$layerDir/python"

if (Test-Path $layerDir) { Remove-Item -Recurse -Force $layerDir }
New-Item -ItemType Directory -Path $pythonDir -Force | Out-Null

# Install dependencies to layer
pip install `
    fastapi mangum uvicorn langchain-core langchain-openai langchain aiohttp python-dotenv pydantic boto3 `
    -t $pythonDir --quiet --upgrade

# Create layer zip
if (Test-Path "lambda-layer.zip") { Remove-Item "lambda-layer.zip" }
Push-Location $layerDir
Compress-Archive -Path "python" -DestinationPath "../lambda-layer.zip"
Pop-Location

# Upload layer to S3 (needed for large layers)
$layerBucket = "$APP_NAME-layers-$AccountId"
$bucketExists = aws s3api head-bucket --bucket $layerBucket 2>$null
if (-not $?) {
    aws s3api create-bucket --bucket $layerBucket --region $Region 2>$null | Out-Null
}
aws s3 cp lambda-layer.zip "s3://$layerBucket/lambda-layer.zip"

# Publish layer
$layerResult = aws lambda publish-layer-version `
    --layer-name "$APP_NAME-dependencies" `
    --content "S3Bucket=$layerBucket,S3Key=lambda-layer.zip" `
    --compatible-runtimes python3.12 `
    --region $Region `
    --output json | ConvertFrom-Json

$layerArn = $layerResult.LayerVersionArn
Write-Host "  Lambda Layer created: $layerArn" -ForegroundColor Green

# Cleanup
Remove-Item -Recurse -Force $layerDir
Remove-Item "lambda-layer.zip"

# Step 3: Create Lambda execution role
Write-Host "`n[3/7] Creating Lambda execution role..." -ForegroundColor Yellow

$trustPolicy = @'
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
'@

$roleExists = aws iam get-role --role-name $LAMBDA_ROLE 2>$null
if (-not $roleExists) {
    $trustPolicy | Out-File -FilePath "trust-policy.json" -Encoding ASCII
    aws iam create-role --role-name $LAMBDA_ROLE --assume-role-policy-document file://trust-policy.json --output json | Out-Null
    aws iam attach-role-policy --role-name $LAMBDA_ROLE --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
    aws iam attach-role-policy --role-name $LAMBDA_ROLE --policy-arn arn:aws:iam::aws:policy/AmazonSSMReadOnlyAccess
    Remove-Item "trust-policy.json"
    Write-Host "  Lambda role created! Waiting 10s for propagation..." -ForegroundColor Green
    Start-Sleep -Seconds 10
} else {
    Write-Host "  Lambda role already exists." -ForegroundColor Green
}

$roleArn = "arn:aws:iam::${AccountId}:role/$LAMBDA_ROLE"

# Step 4: Create Lambda function code zip
Write-Host "`n[4/7] Packaging Lambda function code..." -ForegroundColor Yellow

$codeDir = "lambda-code"
if (Test-Path $codeDir) { Remove-Item -Recurse -Force $codeDir }
New-Item -ItemType Directory -Path $codeDir -Force | Out-Null

Copy-Item "application/api/agent.py" "$codeDir/"
Copy-Item "application/api/lambda_handler.py" "$codeDir/"

if (Test-Path "lambda-code.zip") { Remove-Item "lambda-code.zip" }
Push-Location $codeDir
Compress-Archive -Path "*" -DestinationPath "../lambda-code.zip"
Pop-Location

Write-Host "  Code packaged!" -ForegroundColor Green

# Step 5: Create/Update Lambda function
Write-Host "`n[5/7] Creating Lambda function..." -ForegroundColor Yellow

$lambdaExists = aws lambda get-function --function-name $LAMBDA_FUNCTION --region $Region 2>$null
if (-not $lambdaExists) {
    aws lambda create-function `
        --function-name $LAMBDA_FUNCTION `
        --runtime python3.12 `
        --handler lambda_handler.handler `
        --role $roleArn `
        --zip-file fileb://lambda-code.zip `
        --layers $layerArn `
        --timeout 300 `
        --memory-size 1024 `
        --region $Region `
        --output json | Out-Null
    
    Write-Host "  Lambda function created!" -ForegroundColor Green
    Start-Sleep -Seconds 5
} else {
    aws lambda update-function-code `
        --function-name $LAMBDA_FUNCTION `
        --zip-file fileb://lambda-code.zip `
        --region $Region `
        --output json | Out-Null
    
    Start-Sleep -Seconds 3
    
    aws lambda update-function-configuration `
        --function-name $LAMBDA_FUNCTION `
        --layers $layerArn `
        --region $Region `
        --output json | Out-Null
    
    Write-Host "  Lambda function updated!" -ForegroundColor Green
}

# Cleanup code zip
Remove-Item -Recurse -Force $codeDir
Remove-Item "lambda-code.zip"

# Create Lambda Function URL
Write-Host "`n[6/7] Creating Lambda Function URL..." -ForegroundColor Yellow

$funcUrl = aws lambda get-function-url-config --function-name $LAMBDA_FUNCTION --region $Region 2>$null
if (-not $funcUrl) {
    $funcUrlResult = aws lambda create-function-url-config `
        --function-name $LAMBDA_FUNCTION `
        --auth-type NONE `
        --cors "AllowOrigins=*,AllowMethods=*,AllowHeaders=*" `
        --invoke-mode RESPONSE_STREAM `
        --region $Region `
        --output json | ConvertFrom-Json
    
    aws lambda add-permission `
        --function-name $LAMBDA_FUNCTION `
        --statement-id FunctionURLAllowPublicAccess `
        --action lambda:InvokeFunctionUrl `
        --principal "*" `
        --function-url-auth-type NONE `
        --region $Region 2>$null | Out-Null
    
    $lambdaUrl = $funcUrlResult.FunctionUrl
} else {
    $funcUrlObj = $funcUrl | ConvertFrom-Json
    $lambdaUrl = $funcUrlObj.FunctionUrl
}

Write-Host "  Lambda URL: $lambdaUrl" -ForegroundColor Green

# Step 7: Build and deploy frontend
Write-Host "`n[7/7] Building and deploying frontend to S3..." -ForegroundColor Yellow
Push-Location "application/app"

# Update .env.production with actual Lambda URL
$lambdaUrlClean = $lambdaUrl.TrimEnd('/')
"NEXT_PUBLIC_API_URL=$lambdaUrlClean" | Out-File -FilePath ".env.production" -Encoding ASCII

# Build Next.js static export
npm run build

# Create S3 bucket (handle us-east-1 special case)
$bucketExists = aws s3api head-bucket --bucket $S3_BUCKET 2>$null
if (-not $?) {
    if ($Region -eq "us-east-1") {
        aws s3api create-bucket --bucket $S3_BUCKET --region $Region 2>$null | Out-Null
    } else {
        aws s3api create-bucket --bucket $S3_BUCKET --region $Region --create-bucket-configuration LocationConstraint=$Region 2>$null | Out-Null
    }
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
$bucketPolicy | Out-File -FilePath "bucket-policy.json" -Encoding ASCII
aws s3api put-bucket-policy --bucket $S3_BUCKET --policy file://bucket-policy.json
Remove-Item "bucket-policy.json"

aws s3 website "s3://$S3_BUCKET" --index-document index.html --error-document index.html

# Upload files
aws s3 sync out/ "s3://$S3_BUCKET/" --delete

Pop-Location
Write-Host "  Frontend deployed to S3!" -ForegroundColor Green

# Output results
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "DEPLOYMENT COMPLETE!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan

$s3WebsiteUrl = "http://$S3_BUCKET.s3-website-$Region.amazonaws.com"

Write-Host "`nEndpoints:" -ForegroundColor Yellow
Write-Host "  Frontend (S3):    $s3WebsiteUrl" -ForegroundColor White
Write-Host "  Backend (Lambda): $lambdaUrl" -ForegroundColor White
Write-Host "`nTest the API:" -ForegroundColor Yellow
Write-Host "  Invoke-RestMethod -Method POST -Uri '${lambdaUrl}invoke?content=hello'" -ForegroundColor White
Write-Host "`nTest the Frontend:" -ForegroundColor Yellow
Write-Host "  Start-Process '$s3WebsiteUrl'" -ForegroundColor White
Write-Host "`n"

# Save endpoints to file
@"
FRONTEND_URL=$s3WebsiteUrl
BACKEND_URL=$lambdaUrl
"@ | Out-File -FilePath "deployment-urls.txt" -Encoding ASCII

Write-Host "Endpoints saved to deployment-urls.txt" -ForegroundColor Green
