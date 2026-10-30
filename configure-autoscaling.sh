#!/usr/bin/env bash
set -euo pipefail

# ==========================================
# Configuration Variables
# ==========================================
AWS_REGION="${AWS_REGION:-us-east-1}"
CLUSTER_NAME="${CLUSTER_NAME:-fargate-cluster}"
SERVICE_NAME="${SERVICE_NAME:-fargate-express-service}"
RESOURCE_ID="service/${CLUSTER_NAME}/${SERVICE_NAME}"
MIN_CAPACITY=2
MAX_CAPACITY=10

echo "Configuring Auto Scaling for Resource: ${RESOURCE_ID}"
echo "Region: ${AWS_REGION} | Min Capacity: ${MIN_CAPACITY} | Max Capacity: ${MAX_CAPACITY}"

# ==========================================
# 1. Register Scalable Target
# ==========================================
echo ""
echo "--- 1. Registering ECS Service as Scalable Target ---"
aws application-autoscaling register-scalable-target \
  --region "${AWS_REGION}" \
  --service-namespace ecs \
  --scalable-dimension ecs:service:DesiredCount \
  --resource-id "${RESOURCE_ID}" \
  --min-capacity "${MIN_CAPACITY}" \
  --max-capacity "${MAX_CAPACITY}"

echo "Scalable target registered successfully."

# ==========================================
# 2. Target Tracking Policy: Average CPU Utilization (70%)
# ==========================================
echo ""
echo "--- 2. Creating Target Tracking Policy: CPU (70%) ---"
aws application-autoscaling put-scaling-policy \
  --region "${AWS_REGION}" \
  --policy-name "${SERVICE_NAME}-cpu-target-tracking" \
  --service-namespace ecs \
  --scalable-dimension ecs:service:DesiredCount \
  --resource-id "${RESOURCE_ID}" \
  --policy-type TargetTrackingScaling \
  --target-tracking-scaling-policy-configuration '{
    "TargetValue": 70.0,
    "PredefinedMetricSpecification": {
      "PredefinedMetricType": "ECSServiceAverageCPUUtilization"
    },
    "ScaleOutCooldown": 60,
    "ScaleInCooldown": 300
  }'

echo "CPU Target Tracking policy attached."

# ==========================================
# 3. Target Tracking Policy: Average Memory Utilization (80%)
# ==========================================
echo ""
echo "--- 3. Creating Target Tracking Policy: Memory (80%) ---"
aws application-autoscaling put-scaling-policy \
  --region "${AWS_REGION}" \
  --policy-name "${SERVICE_NAME}-memory-target-tracking" \
  --service-namespace ecs \
  --scalable-dimension ecs:service:DesiredCount \
  --resource-id "${RESOURCE_ID}" \
  --policy-type TargetTrackingScaling \
  --target-tracking-scaling-policy-configuration '{
    "TargetValue": 80.0,
    "PredefinedMetricSpecification": {
      "PredefinedMetricType": "ECSServiceAverageMemoryUtilization"
    },
    "ScaleOutCooldown": 60,
    "ScaleInCooldown": 300
  }'

echo "Memory Target Tracking policy attached."

# ==========================================
# Summary
# ==========================================
echo ""
echo "=========================================="
echo "Application Auto Scaling Configured!"
echo "=========================================="
echo "Resource ID : ${RESOURCE_ID}"
echo "Capacity    : Min ${MIN_CAPACITY} / Max ${MAX_CAPACITY}"
echo "Policies    : CPU 70% | Memory 80%"
echo "=========================================="
