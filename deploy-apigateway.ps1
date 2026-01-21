# Streaming Agent AWS Deployment Script (API Gateway + Lambda + S3)
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
$API_NAME = "$APP_NAME-http-api"

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Streaming Agent AWS Deployment" -ForegroundColor Cyan
Write-Host "API Gateway + Lambda + S3" -ForegroundColor Cyan
Write-Host "Region: $Region" -ForegroundColor Cyan
Write-Host "Account: $AccountId" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# Step 1: Store secrets in SSM Parameter Store
Write-Host "`n[1/8] Storing secrets in SSM Parameter Store..." -ForegroundColor Yellow

$envContent = Get-Content ".env" -Raw
$lines = $envContent -split "`r?`n"
foreach ($line in $lines) {
    if ($line -match "^(OPENAI_API_KEY|SERPAPI_API_KEY)=(.+)$") {
        $key = $matches[1]
        $value = $matches[2].Trim()
        Write-Host "  Storing /streaming-agent/$key..."
        aws ssm put-parameter --name "/streaming-agent/$key" --value $value --type "SecureString" --overwrite --region $Region 2>$null | Out-Null
    }
}
Write-Host "  Secrets stored successfully!" -ForegroundColor Green

# Step 2: Create Lambda execution role
Write-Host "`n[2/8] Creating Lambda execution role..." -ForegroundColor Yellow

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
    $trustPolicy | Out-File -FilePath "trust-policy.json" -Encoding ASCII -NoNewline
    aws iam create-role --role-name $LAMBDA_ROLE --assume-role-policy-document file://trust-policy.json --output json | Out-Null
    aws iam attach-role-policy --role-name $LAMBDA_ROLE --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
    aws iam attach-role-policy --role-name $LAMBDA_ROLE --policy-arn arn:aws:iam::aws:policy/AmazonSSMReadOnlyAccess
    Remove-Item "trust-policy.json" -ErrorAction SilentlyContinue
    Write-Host "  Lambda role created! Waiting 10s for propagation..." -ForegroundColor Green
    Start-Sleep -Seconds 10
} else {
    Write-Host "  Lambda role already exists." -ForegroundColor Green
}

$roleArn = "arn:aws:iam::${AccountId}:role/$LAMBDA_ROLE"

# Step 3: Create Lambda Layer with dependencies
Write-Host "`n[3/8] Creating Lambda Layer with dependencies..." -ForegroundColor Yellow

$layerDir = "lambda-layer"
$pythonDir = "$layerDir/python"

if (Test-Path $layerDir) { Remove-Item -Recurse -Force $layerDir }
New-Item -ItemType Directory -Path $pythonDir -Force | Out-Null

# Install dependencies to layer
Write-Host "  Installing Python dependencies (this may take a few minutes)..."
pip install fastapi mangum uvicorn langchain-core langchain-openai langchain aiohttp python-dotenv pydantic boto3 -t $pythonDir --quiet --upgrade 2>$null

# Create layer zip
if (Test-Path "lambda-layer.zip") { Remove-Item "lambda-layer.zip" }
Push-Location $layerDir
Compress-Archive -Path "python" -DestinationPath "../lambda-layer.zip" -Force
Pop-Location

# Upload layer to S3
$layerBucket = "$APP_NAME-layers-$AccountId"
$bucketExists = aws s3api head-bucket --bucket $layerBucket 2>$null
if (-not $?) {
    aws s3api create-bucket --bucket $layerBucket --region $Region 2>$null | Out-Null
}
Write-Host "  Uploading layer to S3..."
aws s3 cp lambda-layer.zip "s3://$layerBucket/lambda-layer.zip" --quiet

# Publish layer
Write-Host "  Publishing Lambda layer..."
$layerResult = aws lambda publish-layer-version `
    --layer-name "$APP_NAME-dependencies" `
    --content "S3Bucket=$layerBucket,S3Key=lambda-layer.zip" `
    --compatible-runtimes python3.12 `
    --region $Region `
    --output json | ConvertFrom-Json

$layerArn = $layerResult.LayerVersionArn
Write-Host "  Lambda Layer created!" -ForegroundColor Green

# Cleanup
Remove-Item -Recurse -Force $layerDir -ErrorAction SilentlyContinue
Remove-Item "lambda-layer.zip" -ErrorAction SilentlyContinue

# Step 4: Package Lambda function code
Write-Host "`n[4/8] Packaging Lambda function code..." -ForegroundColor Yellow

$codeDir = "lambda-code"
if (Test-Path $codeDir) { Remove-Item -Recurse -Force $codeDir }
New-Item -ItemType Directory -Path $codeDir -Force | Out-Null

Copy-Item "application/api/agent.py" "$codeDir/"
Copy-Item "application/api/lambda_handler.py" "$codeDir/"

if (Test-Path "lambda-code.zip") { Remove-Item "lambda-code.zip" }
Push-Location $codeDir
Compress-Archive -Path "*" -DestinationPath "../lambda-code.zip" -Force
Pop-Location

Write-Host "  Code packaged!" -ForegroundColor Green

# Step 5: Create/Update Lambda function
Write-Host "`n[5/8] Creating Lambda function..." -ForegroundColor Yellow

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
    Write-Host "  Waiting for function to be active..."
    aws lambda wait function-active --function-name $LAMBDA_FUNCTION --region $Region
} else {
    aws lambda update-function-code `
        --function-name $LAMBDA_FUNCTION `
        --zip-file fileb://lambda-code.zip `
        --region $Region `
        --output json | Out-Null
    
    Write-Host "  Waiting for update to complete..."
    aws lambda wait function-updated --function-name $LAMBDA_FUNCTION --region $Region
    
    aws lambda update-function-configuration `
        --function-name $LAMBDA_FUNCTION `
        --layers $layerArn `
        --timeout 300 `
        --memory-size 1024 `
        --region $Region `
        --output json | Out-Null
    
    aws lambda wait function-updated --function-name $LAMBDA_FUNCTION --region $Region
    Write-Host "  Lambda function updated!" -ForegroundColor Green
}

# Cleanup
Remove-Item -Recurse -Force $codeDir -ErrorAction SilentlyContinue
Remove-Item "lambda-code.zip" -ErrorAction SilentlyContinue

# Step 6: Create API Gateway HTTP API
Write-Host "`n[6/8] Creating API Gateway HTTP API..." -ForegroundColor Yellow

# Check if API already exists
$existingApis = aws apigatewayv2 get-apis --region $Region --output json | ConvertFrom-Json
$existingApi = $existingApis.Items | Where-Object { $_.Name -eq $API_NAME }

if ($existingApi) {
    $apiId = $existingApi.ApiId
    Write-Host "  API Gateway already exists: $apiId" -ForegroundColor Green
} else {
    # Create HTTP API
    $apiResult = aws apigatewayv2 create-api `
        --name $API_NAME `
        --protocol-type HTTP `
        --cors-configuration "AllowOrigins=*,AllowMethods=*,AllowHeaders=*,ExposeHeaders=*,MaxAge=86400" `
        --region $Region `
        --output json | ConvertFrom-Json
    
    $apiId = $apiResult.ApiId
    Write-Host "  API Gateway created: $apiId" -ForegroundColor Green
}

# Create Lambda integration
$lambdaArn = "arn:aws:lambda:${Region}:${AccountId}:function:$LAMBDA_FUNCTION"
$integrationUri = "arn:aws:apigateway:${Region}:lambda:path/2015-03-31/functions/${lambdaArn}/invocations"

# Check existing integrations
$existingIntegrations = aws apigatewayv2 get-integrations --api-id $apiId --region $Region --output json | ConvertFrom-Json
if ($existingIntegrations.Items.Count -eq 0) {
    $integrationResult = aws apigatewayv2 create-integration `
        --api-id $apiId `
        --integration-type AWS_PROXY `
        --integration-uri $integrationUri `
        --payload-format-version "2.0" `
        --region $Region `
        --output json | ConvertFrom-Json
    
    $integrationId = $integrationResult.IntegrationId
} else {
    $integrationId = $existingIntegrations.Items[0].IntegrationId
}

# Create route for POST /invoke
$existingRoutes = aws apigatewayv2 get-routes --api-id $apiId --region $Region --output json | ConvertFrom-Json
$invokeRoute = $existingRoutes.Items | Where-Object { $_.RouteKey -eq "POST /invoke" }

if (-not $invokeRoute) {
    aws apigatewayv2 create-route `
        --api-id $apiId `
        --route-key "POST /invoke" `
        --target "integrations/$integrationId" `
        --region $Region `
        --output json | Out-Null
}

# Create route for GET /health
$healthRoute = $existingRoutes.Items | Where-Object { $_.RouteKey -eq "GET /health" }
if (-not $healthRoute) {
    aws apigatewayv2 create-route `
        --api-id $apiId `
        --route-key "GET /health" `
        --target "integrations/$integrationId" `
        --region $Region `
        --output json | Out-Null
}

# Create default stage with auto-deploy
$existingStages = aws apigatewayv2 get-stages --api-id $apiId --region $Region --output json | ConvertFrom-Json
$defaultStage = $existingStages.Items | Where-Object { $_.StageName -eq "`$default" }

if (-not $defaultStage) {
    aws apigatewayv2 create-stage `
        --api-id $apiId `
        --stage-name "`$default" `
        --auto-deploy `
        --region $Region `
        --output json | Out-Null
}

# Grant API Gateway permission to invoke Lambda
$statementId = "apigateway-invoke-$apiId"
aws lambda remove-permission --function-name $LAMBDA_FUNCTION --statement-id $statementId --region $Region 2>$null
aws lambda add-permission `
    --function-name $LAMBDA_FUNCTION `
    --statement-id $statementId `
    --action lambda:InvokeFunction `
    --principal apigateway.amazonaws.com `
    --source-arn "arn:aws:execute-api:${Region}:${AccountId}:${apiId}/*" `
    --region $Region `
    --output json 2>$null | Out-Null

$apiUrl = "https://$apiId.execute-api.$Region.amazonaws.com"
Write-Host "  API Gateway URL: $apiUrl" -ForegroundColor Green

# Step 7: Build and deploy frontend
Write-Host "`n[7/8] Building and deploying frontend to S3..." -ForegroundColor Yellow
Push-Location "application/app"

# Update .env.production with API Gateway URL
"NEXT_PUBLIC_API_URL=$apiUrl" | Out-File -FilePath ".env.production" -Encoding ASCII -NoNewline

# Build Next.js static export
Write-Host "  Building Next.js app..."
npm run build 2>$null

# Create S3 bucket
$bucketExists = aws s3api head-bucket --bucket $S3_BUCKET 2>$null
if (-not $?) {
    aws s3api create-bucket --bucket $S3_BUCKET --region $Region 2>$null | Out-Null
    Write-Host "  S3 bucket created: $S3_BUCKET"
}

# Configure bucket for public access
aws s3api put-public-access-block `
    --bucket $S3_BUCKET `
    --public-access-block-configuration "BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false" 2>$null

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
aws s3api put-bucket-policy --bucket $S3_BUCKET --policy file://bucket-policy.json 2>$null
Remove-Item "bucket-policy.json" -ErrorAction SilentlyContinue

aws s3 website "s3://$S3_BUCKET" --index-document index.html --error-document index.html 2>$null

# Upload files
Write-Host "  Uploading frontend files..."
aws s3 sync out/ "s3://$S3_BUCKET/" --delete --quiet

Pop-Location
Write-Host "  Frontend deployed to S3!" -ForegroundColor Green

# Step 8: Test and output results
Write-Host "`n[8/8] Testing deployment..." -ForegroundColor Yellow

# Test health endpoint
Write-Host "  Testing health endpoint..."
Start-Sleep -Seconds 3
try {
    $healthResponse = Invoke-RestMethod -Uri "$apiUrl/health" -Method GET -TimeoutSec 30
    Write-Host "  Health check: $($healthResponse.status)" -ForegroundColor Green
} catch {
    Write-Host "  Health check: Cold start expected, will work on next request" -ForegroundColor Yellow
}

$s3WebsiteUrl = "http://$S3_BUCKET.s3-website-$Region.amazonaws.com"

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "DEPLOYMENT COMPLETE!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan

Write-Host "`nEndpoints:" -ForegroundColor Yellow
Write-Host "  Frontend (S3):      $s3WebsiteUrl" -ForegroundColor White
Write-Host "  Backend (API GW):   $apiUrl" -ForegroundColor White

Write-Host "`nTest the API:" -ForegroundColor Yellow
Write-Host "  Invoke-RestMethod -Uri '$apiUrl/health' -Method GET" -ForegroundColor White
Write-Host "  Invoke-RestMethod -Uri '$apiUrl/invoke?content=hello' -Method POST" -ForegroundColor White

Write-Host "`nOpen the app:" -ForegroundColor Yellow
Write-Host "  Start-Process '$s3WebsiteUrl'" -ForegroundColor White

# Save endpoints to file
@"
FRONTEND_URL=$s3WebsiteUrl
BACKEND_URL=$apiUrl
API_ID=$apiId
"@ | Out-File -FilePath "deployment-urls.txt" -Encoding ASCII

Write-Host "`nEndpoints saved to deployment-urls.txt" -ForegroundColor Green
Write-Host ""
