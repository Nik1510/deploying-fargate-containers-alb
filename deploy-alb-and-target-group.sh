#!/usr/bin/env bash
set -euo pipefail

# ==========================================
# Configuration Variables
# ==========================================
AWS_REGION="${AWS_REGION:-us-east-1}"
PROJECT_NAME="${PROJECT_NAME:-fargate-express-app}"
VPC_ID="${VPC_ID:-}"
ALB_SG_ID="${ALB_SG_ID:-}"
SUBNET_IDS="${SUBNET_IDS:-}" # Space-separated subnet IDs (minimum 2 in different AZs)

echo "Region: ${AWS_REGION}"

# 1. Discover VPC and Subnets if not provided
if [ -z "${VPC_ID}" ]; then
  VPC_ID=$(aws ec2 describe-vpcs \
    --region "${AWS_REGION}" \
    --filters "Name=is-default,Values=true" \
    --query "Vpcs[0].VpcId" \
    --output text)
fi

if [ -z "${SUBNET_IDS}" ]; then
  SUBNET_IDS=$(aws ec2 describe-subnets \
    --region "${AWS_REGION}" \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
    --query "Subnets[0:2].SubnetId" \
    --output text)
fi

if [ -z "${ALB_SG_ID}" ]; then
  ALB_SG_ID=$(aws ec2 describe-security-groups \
    --region "${AWS_REGION}" \
    --filters "Name=group-name,Values=${PROJECT_NAME}-alb-sg" "Name=vpc-id,Values=${VPC_ID}" \
    --query "SecurityGroups[0].GroupId" \
    --output text)
fi

echo "VPC: ${VPC_ID}"
echo "Subnets: ${SUBNET_IDS}"
echo "ALB Security Group: ${ALB_SG_ID}"

# ==========================================
# 1. Create Target Group (target-type = ip)
# ==========================================
TG_NAME="${PROJECT_NAME}-tg"
echo ""
echo "--- 1. Creating Target Group: ${TG_NAME} ---"

TARGET_GROUP_ARN=$(aws elbv2 describe-target-groups \
  --region "${AWS_REGION}" \
  --names "${TG_NAME}" \
  --query "TargetGroups[0].TargetGroupArn" \
  --output text 2>/dev/null || echo "None")

if [ "${TARGET_GROUP_ARN}" == "None" ] || [ -z "${TARGET_GROUP_ARN}" ]; then
  TARGET_GROUP_ARN=$(aws elbv2 create-target-group \
    --region "${AWS_REGION}" \
    --name "${TG_NAME}" \
    --protocol HTTP \
    --port 3000 \
    --vpc-id "${VPC_ID}" \
    --target-type ip \
    --health-check-protocol HTTP \
    --health-check-path /health \
    --health-check-interval-seconds 30 \
    --health-check-timeout-seconds 5 \
    --healthy-threshold-count 2 \
    --unhealthy-threshold-count 3 \
    --matcher HttpCode=200 \
    --query "TargetGroups[0].TargetGroupArn" \
    --output text)
  echo "Target Group created: ${TARGET_GROUP_ARN}"
else
  echo "Target Group already exists: ${TARGET_GROUP_ARN}"
fi

# ==========================================
# 2. Create Application Load Balancer
# ==========================================
ALB_NAME="${PROJECT_NAME}-alb"
echo ""
echo "--- 2. Creating ALB: ${ALB_NAME} ---"

ALB_ARN=$(aws elbv2 describe-load-balancers \
  --region "${AWS_REGION}" \
  --names "${ALB_NAME}" \
  --query "LoadBalancers[0].LoadBalancerArn" \
  --output text 2>/dev/null || echo "None")

if [ "${ALB_ARN}" == "None" ] || [ -z "${ALB_ARN}" ]; then
  ALB_ARN=$(aws elbv2 create-load-balancer \
    --region "${AWS_REGION}" \
    --name "${ALB_NAME}" \
    --subnets ${SUBNET_IDS} \
    --security-groups "${ALB_SG_ID}" \
    --scheme internet-facing \
    --type application \
    --ip-address-type ipv4 \
    --query "LoadBalancers[0].LoadBalancerArn" \
    --output text)
  echo "ALB created: ${ALB_ARN}"
else
  echo "ALB already exists: ${ALB_ARN}"
fi

# ==========================================
# 3. Create HTTP Listener on Port 80
# ==========================================
echo ""
echo "--- 3. Creating Listener on port 80 ---"

LISTENER_ARN=$(aws elbv2 describe-listeners \
  --region "${AWS_REGION}" \
  --load-balancer-arn "${ALB_ARN}" \
  --query "Listeners[?Port==\`80\`].ListenerArn" \
  --output text 2>/dev/null || echo "None")

if [ "${LISTENER_ARN}" == "None" ] || [ -z "${LISTENER_ARN}" ]; then
  LISTENER_ARN=$(aws elbv2 create-listener \
    --region "${AWS_REGION}" \
    --load-balancer-arn "${ALB_ARN}" \
    --protocol HTTP \
    --port 80 \
    --default-actions Type=forward,TargetGroupArn="${TARGET_GROUP_ARN}" \
    --query "Listeners[0].ListenerArn" \
    --output text)
  echo "HTTP Listener created: ${LISTENER_ARN}"
else
  echo "HTTP Listener already exists on port 80: ${LISTENER_ARN}"
fi

echo ""
echo "=========================================="
echo "ALB & Target Group Setup Summary"
echo "=========================================="
echo "Target Group ARN : ${TARGET_GROUP_ARN}"
echo "ALB ARN          : ${ALB_ARN}"
echo "Listener ARN     : ${LISTENER_ARN}"
echo "=========================================="
