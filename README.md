# LangChain Streaming Agent

A real-time streaming AI chat application built with LangChain, FastAPI, and Next.js. The agent uses tools (web search, math) to answer questions and streams responses live to the user.

## Project Structure

```
├── application/
│   ├── api/          # Original FastAPI backend (for local dev)
│   └── app/          # Next.js frontend
├── lambda-code/      # AWS Lambda deployment code
│   ├── app.py        # FastAPI app with streaming
│   ├── agent.py      # LangChain agent with tools
│   └── run.sh        # Lambda Web Adapter bootstrap
└── documentation/    # Project documentation (Word docs)
```

## Features

- **Real-time Streaming**: See tools being called as the agent processes your query
- **Multiple Tools**: Web search (SerpAPI), math operations, final answer
- **Serverless**: Runs on AWS Lambda

## Local Development

### Backend
```bash
cd application/api
pip install -r requirements.txt
uvicorn main:app --reload --port 8000
```

### Frontend
```bash
cd application/app
npm install
npm run dev
```

### Environment Variables
Create `.env` file:
```
OPENAI_API_KEY=...
SERPAPI_API_KEY=...
```

---

## AWS Deployment

### Prerequisites
- AWS CLI configured with credentials
- AWS account

### Architecture
```
S3 (Frontend) → Lambda Function URL → Lambda (FastAPI + LangChain)
                                           ↓
                               OpenAI API + SerpAPI
```

### Step 1: Store API Keys in SSM
```bash
aws ssm put-parameter --name "/streaming-agent/OPENAI_API_KEY" \
    --value "sk-your-key" --type SecureString --region us-east-1

aws ssm put-parameter --name "/streaming-agent/SERPAPI_API_KEY" \
    --value "your-key" --type SecureString --region us-east-1
```

### Step 2: Create Lambda Role
```bash
aws iam create-role --role-name streaming-agent-lambda-role \
    --assume-role-policy-document '{
        "Version": "2012-10-17",
        "Statement": [{
            "Effect": "Allow",
            "Principal": {"Service": "lambda.amazonaws.com"},
            "Action": "sts:AssumeRole"
        }]
    }'

aws iam put-role-policy --role-name streaming-agent-lambda-role \
    --policy-name streaming-agent-policy \
    --policy-document '{
        "Version": "2012-10-17",
        "Statement": [
            {"Effect": "Allow", "Action": ["logs:*"], "Resource": "*"},
            {"Effect": "Allow", "Action": ["ssm:GetParameters"], 
             "Resource": "arn:aws:ssm:*:*:parameter/streaming-agent/*"}
        ]
    }'
```

### Step 3: Create Lambda Dependencies Layer
```bash
mkdir -p layer/python
pip install langchain-core langchain-openai pydantic boto3 aiohttp \
    -t layer/python --platform manylinux2014_x86_64 --only-binary=:all:

cd layer && zip -r ../layer.zip python && cd ..

aws lambda publish-layer-version --layer-name streaming-agent-dependencies \
    --zip-file fileb://layer.zip --compatible-runtimes python3.12 --region us-east-1
```

### Step 4: Create FastAPI Layer
```bash
mkdir -p layer-fastapi/python
pip install fastapi uvicorn starlette \
    -t layer-fastapi/python --platform manylinux2014_x86_64 --only-binary=:all:

cd layer-fastapi && zip -r ../layer-fastapi.zip python && cd ..

aws lambda publish-layer-version --layer-name streaming-agent-fastapi \
    --zip-file fileb://layer-fastapi.zip --compatible-runtimes python3.12 --region us-east-1
```

### Step 5: Deploy Lambda Function
```bash
cd lambda-code
zip lambda.zip *.py run.sh

aws lambda create-function --function-name streaming-agent-api \
    --runtime python3.12 --handler run.sh --role <ROLE_ARN> \
    --zip-file fileb://lambda.zip --timeout 300 --memory-size 1536 \
    --layers <DEPS_LAYER_ARN> <FASTAPI_LAYER_ARN> \
        arn:aws:lambda:us-east-1:753240598075:layer:LambdaAdapterLayerX86:24 \
    --environment "Variables={
        AWS_LAMBDA_EXEC_WRAPPER=/opt/bootstrap,
        AWS_LWA_INVOKE_MODE=response_stream,
        PORT=8080,
        PYTHONPATH=/opt/python:/var/task
    }" --region us-east-1
```

### Step 6: Create Function URL
```bash
aws lambda create-function-url-config --function-name streaming-agent-api \
    --auth-type NONE --invoke-mode RESPONSE_STREAM \
    --cors 'AllowOrigins=*,AllowMethods=*,AllowHeaders=*,ExposeHeaders=*' \
    --region us-east-1
```


# Create S3 bucket
aws s3 mb s3://streaming-agent-frontend-<> --region us-east-1

# Enable static website hosting
aws s3 website s3://streaming-agent-frontend-<> \
    --index-document index.html --error-document 404.html

# Upload files
aws s3 sync out/ s3://streaming-agent-frontend-<> --region us-east-1

# Make public
aws s3api put-bucket-policy --bucket streaming-agent-frontend-<> \
    --policy '{
        "Version": "2012-10-17",
        "Statement": [{
            "Effect": "Allow",
            "Principal": "*",
            "Action": "s3:GetObject",
            "Resource": "arn:aws:s3:::streaming-agent-frontend-<>/*"
        }]
    }'
```

### Step 8: Access  App
- **Frontend**: `http://streaming-agent-frontend-125975759762.s3-website-us-east-1.amazonaws.com/`

---

