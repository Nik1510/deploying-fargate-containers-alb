#!/usr/bin/env bash
set -euo pipefail

# ==========================================
# Configuration Variables
# ==========================================
AWS_REGION="${AWS_REGION:-us-east-1}"
PROJECT_NAME="${PROJECT_NAME:-fargate-express-app}"
VPC_ID="${VPC_ID:-}" # Required: set your VPC ID or export VPC_ID before running
APP_PORT=3000

echo "Using AWS Region: ${AWS_REGION}"
echo "Using Project Name: ${PROJECT_NAME}"

# Validate VPC_ID or fetch default VPC
if [ -z "${VPC_ID}" ]; then
  echo "VPC_ID not provided. Attempting to discover default VPC..."
  VPC_ID=$(aws ec2 describe-vpcs \
    --region "${AWS_REGION}" \
    --filters "Name=is-default,Values=true" \
    --query "Vpcs[0].VpcId" \
    --output text)

  if [ "${VPC_ID}" == "None" ] || [ -z "${VPC_ID}" ]; then
    echo "Error: Default VPC not found. Please provide a VPC ID via 'export VPC_ID=vpc-xxxxxx'." >&2
    exit 1
  fi
fi
echo "Using VPC ID: ${VPC_ID}"

# ==========================================
# 1. Create ECR Repository with Vulnerability Scanning
# ==========================================
ECR_REPO_NAME="${PROJECT_NAME}"
echo ""
echo "--- 1. Creating/Verifying ECR Repository: ${ECR_REPO_NAME} ---"

# Check if repository already exists
REPO_EXISTS=$(aws ecr describe-repositories \
  --region "${AWS_REGION}" \
  --repository-names "${ECR_REPO_NAME}" \
  --query "repositories[0].repositoryName" \
  --output text 2>/dev/null || echo "not_found")

if [ "${REPO_EXISTS}" == "not_found" ]; then
  echo "Creating ECR repository with scan-on-push enabled..."
  aws ecr create-repository \
    --region "${AWS_REGION}" \
    --repository-name "${ECR_REPO_NAME}" \
    --image-scanning-configuration scanOnPush=true \
    --image-tag-mutability MUTABLE \
    --tags Key=Project,Value="${PROJECT_NAME}"
else
  echo "ECR repository '${ECR_REPO_NAME}' already exists. Ensuring scan-on-push is enabled..."
  aws ecr put-image-scanning-configuration \
    --region "${AWS_REGION}" \
    --repository-name "${ECR_REPO_NAME}" \
    --image-scanning-configuration scanOnPush=true > /dev/null
fi

ECR_REPO_URI=$(aws ecr describe-repositories \
  --region "${AWS_REGION}" \
  --repository-names "${ECR_REPO_NAME}" \
  --query "repositories[0].repositoryUri" \
  --output text)

echo "ECR Repository URI: ${ECR_REPO_URI}"

# ==========================================
# 2. Create ALB Security Group (Inbound HTTP/HTTPS from 0.0.0.0/0)
# ==========================================
ALB_SG_NAME="${PROJECT_NAME}-alb-sg"
echo ""
echo "--- 2. Creating ALB Security Group: ${ALB_SG_NAME} ---"

ALB_SG_ID=$(aws ec2 describe-security-groups \
  --region "${AWS_REGION}" \
  --filters "Name=group-name,Values=${ALB_SG_NAME}" "Name=vpc-id,Values=${VPC_ID}" \
  --query "SecurityGroups[0].GroupId" \
  --output text 2>/dev/null || echo "None")

if [ "${ALB_SG_ID}" == "None" ] || [ -z "${ALB_SG_ID}" ]; then
  echo "Creating Security Group for ALB..."
  ALB_SG_ID=$(aws ec2 create-security-group \
    --region "${AWS_REGION}" \
    --group-name "${ALB_SG_NAME}" \
    --description "Security Group for ALB allowing public HTTP and HTTPS access" \
    --vpc-id "${VPC_ID}" \
    --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${ALB_SG_NAME}},{Key=Project,Value=${PROJECT_NAME}}]" \
    --query "GroupId" \
    --output text)
  echo "Created ALB Security Group: ${ALB_SG_ID}"
else
  echo "ALB Security Group already exists: ${ALB_SG_ID}"
fi

echo "Configuring inbound rules for ALB Security Group (ports 80 and 443)..."
aws ec2 authorize-security-group-ingress \
  --region "${AWS_REGION}" \
  --group-id "${ALB_SG_ID}" \
  --ip-permissions '[
    {
      "IpProtocol": "tcp",
      "FromPort": 80,
      "ToPort": 80,
      "IpRanges": [{"CidrIp": "0.0.0.0/0", "Description": "Allow HTTP from internet"}]
    },
    {
      "IpProtocol": "tcp",
      "FromPort": 443,
      "ToPort": 443,
      "IpRanges": [{"CidrIp": "0.0.0.0/0", "Description": "Allow HTTPS from internet"}]
    }
  ]' 2>/dev/null || echo "Inbound rules for ports 80/443 already present on ${ALB_SG_ID}."

# ==========================================
# 3. Create Fargate Security Group (Inbound port 3000 strictly from ALB SG)
# ==========================================
FARGATE_SG_NAME="${PROJECT_NAME}-fargate-sg"
echo ""
echo "--- 3. Creating Fargate Task Security Group: ${FARGATE_SG_NAME} ---"

FARGATE_SG_ID=$(aws ec2 describe-security-groups \
  --region "${AWS_REGION}" \
  --filters "Name=group-name,Values=${FARGATE_SG_NAME}" "Name=vpc-id,Values=${VPC_ID}" \
  --query "SecurityGroups[0].GroupId" \
  --output text 2>/dev/null || echo "None")

if [ "${FARGATE_SG_ID}" == "None" ] || [ -z "${FARGATE_SG_ID}" ]; then
  echo "Creating Security Group for Fargate Tasks..."
  FARGATE_SG_ID=$(aws ec2 create-security-group \
    --region "${AWS_REGION}" \
    --group-name "${FARGATE_SG_NAME}" \
    --description "Security Group for Fargate container tasks allowing traffic only from ALB" \
    --vpc-id "${VPC_ID}" \
    --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${FARGATE_SG_NAME}},{Key=Project,Value=${PROJECT_NAME}}]" \
    --query "GroupId" \
    --output text)
  echo "Created Fargate Security Group: ${FARGATE_SG_ID}"
else
  echo "Fargate Security Group already exists: ${FARGATE_SG_ID}"
fi

echo "Configuring inbound rules: allow port ${APP_PORT} strictly from ALB Security Group (${ALB_SG_ID})..."
aws ec2 authorize-security-group-ingress \
  --region "${AWS_REGION}" \
  --group-id "${FARGATE_SG_ID}" \
  --ip-permissions "[
    {
      \"IpProtocol\": \"tcp\",
      \"FromPort\": ${APP_PORT},
      \"ToPort\": ${APP_PORT},
      \"UserIdGroupPairs\": [
        {
          \"GroupId\": \"${ALB_SG_ID}\",
          \"Description\": \"Allow inbound port ${APP_PORT} strictly from ALB Security Group\"
        }
      ]
    }
  ]" 2>/dev/null || echo "Inbound rule for port ${APP_PORT} from ${ALB_SG_ID} already present on ${FARGATE_SG_ID}."

# ==========================================
# Summary
# ==========================================
echo ""
echo "=========================================="
echo "Deployment Foundation Setup Completed!"
echo "=========================================="
echo "ECR Repository URI    : ${ECR_REPO_URI}"
echo "ALB Security Group ID : ${ALB_SG_ID}"
echo "Fargate SG ID         : ${FARGATE_SG_ID}"
echo "VPC ID                : ${VPC_ID}"
echo "Region                : ${AWS_REGION}"
echo "=========================================="
