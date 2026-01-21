# IAM Setup for streaming_agent User

## Option 1: Attach AWS Managed Policies (Quick Setup)
Run these commands as an AWS admin user:

```bash
# Attach required managed policies to streaming_agent
aws iam attach-user-policy --user-name streaming_agent --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess
aws iam attach-user-policy --user-name streaming_agent --policy-arn arn:aws:iam::aws:policy/AWSLambda_FullAccess
aws iam attach-user-policy --user-name streaming_agent --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryFullAccess
aws iam attach-user-policy --user-name streaming_agent --policy-arn arn:aws:iam::aws:policy/CloudFrontFullAccess
aws iam attach-user-policy --user-name streaming_agent --policy-arn arn:aws:iam::aws:policy/AmazonSSMFullAccess
aws iam attach-user-policy --user-name streaming_agent --policy-arn arn:aws:iam::aws:policy/CloudWatchLogsFullAccess
aws iam attach-user-policy --user-name streaming_agent --policy-arn arn:aws:iam::aws:policy/IAMFullAccess
```

## Option 2: Create Custom Policy (Least Privilege)
Use the iam-policy.json file in this directory:

```bash
aws iam create-policy --policy-name streaming-agent-deployment-policy --policy-document file://aws/iam-policy.json
aws iam attach-user-policy --user-name streaming_agent --policy-arn arn:aws:iam::125975759762:policy/streaming-agent-deployment-policy
```

## Verify Permissions
After attaching, verify with:
```bash
aws iam list-attached-user-policies --user-name streaming_agent
```
