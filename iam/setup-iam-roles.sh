#!/usr/bin/env bash
set -euo pipefail

# ==========================================
# IAM Roles Setup for ECS Fargate
# ==========================================
EXECUTION_ROLE_NAME="${EXECUTION_ROLE_NAME:-ecsTaskExecutionRole}"
TASK_ROLE_NAME="${TASK_ROLE_NAME:-ecsTaskRole}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRUST_POLICY_PATH="${SCRIPT_DIR}/ecs-tasks-trust-policy.json"
TASK_POLICY_PATH="${SCRIPT_DIR}/ecs-task-role-policy.json"

echo "Using Execution Role Name : ${EXECUTION_ROLE_NAME}"
echo "Using Task Role Name      : ${TASK_ROLE_NAME}"

# ------------------------------------------
# 1. ECS Task Execution Role
# ------------------------------------------
echo ""
echo "--- 1. Creating ECS Task Execution Role ---"
if aws iam get-role --role-name "${EXECUTION_ROLE_NAME}" >/dev/null 2>&1; then
  echo "Role '${EXECUTION_ROLE_NAME}' already exists."
else
  aws iam create-role \
    --role-name "${EXECUTION_ROLE_NAME}" \
    --assume-role-policy-document "file://${TRUST_POLICY_PATH}" \
    --description "Role for ECS agent and Fargate infrastructure to pull images and publish logs"
  echo "Created role '${EXECUTION_ROLE_NAME}'."
fi

echo "Attaching AWS managed policy AmazonECSTaskExecutionRolePolicy..."
aws iam attach-role-policy \
  --role-name "${EXECUTION_ROLE_NAME}" \
  --policy-arn "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"

EXECUTION_ROLE_ARN=$(aws iam get-role --role-name "${EXECUTION_ROLE_NAME}" --query "Role.Arn" --output text)
echo "Task Execution Role ARN: ${EXECUTION_ROLE_ARN}"

# ------------------------------------------
# 2. ECS Task Role (Application Role)
# ------------------------------------------
echo ""
echo "--- 2. Creating ECS Task Role ---"
if aws iam get-role --role-name "${TASK_ROLE_NAME}" >/dev/null 2>&1; then
  echo "Role '${TASK_ROLE_NAME}' already exists."
else
  aws iam create-role \
    --role-name "${TASK_ROLE_NAME}" \
    --assume-role-policy-document "file://${TRUST_POLICY_PATH}" \
    --description "Role for application containers to interact with AWS services (CloudWatch Logs & Metrics)"
  echo "Created role '${TASK_ROLE_NAME}'."
fi

echo "Attaching custom inline policy for CloudWatch Logs and Metrics..."
aws iam put-role-policy \
  --role-name "${TASK_ROLE_NAME}" \
  --policy-name "ecsTaskCloudWatchPolicy" \
  --policy-document "file://${TASK_POLICY_PATH}"

TASK_ROLE_ARN=$(aws iam get-role --role-name "${TASK_ROLE_NAME}" --query "Role.Arn" --output text)
echo "Task Role ARN: ${TASK_ROLE_ARN}"

# ------------------------------------------
# Summary
# ------------------------------------------
echo ""
echo "=========================================="
echo "IAM Roles Ready for ECS Fargate Tasks"
echo "=========================================="
echo "Task Execution Role ARN : ${EXECUTION_ROLE_ARN}"
echo "Task Role ARN           : ${TASK_ROLE_ARN}"
echo "=========================================="
