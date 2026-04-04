#!/usr/bin/env bash
set -euo pipefail

AWS_ACCOUNT_ID="105299590490"
AWS_REGION="us-east-1"
ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

usage() {
  echo "Usage: ./deploy/deploy.sh <environment> <service> <action>"
  echo ""
  echo "  environment: prod"
  echo "  service:     api"
  echo "  action:      push"
  echo ""
  echo "Example: ./deploy/deploy.sh prod api push"
  exit 1
}

ENV="${1:-}"
SERVICE="${2:-}"
ACTION="${3:-}"

[[ -z "$ENV" || -z "$SERVICE" || -z "$ACTION" ]] && usage

case "$ENV" in
  prod) ECS_CLUSTER="nexus-cluster" ;;
  *)    echo "Error: unknown environment '$ENV'"; usage ;;
esac

case "$SERVICE" in
  api)
    ECR_REPO="nexus-api"
    DOCKERFILE="deploy/api/Dockerfile"
    ;;
  *)
    echo "Error: unknown service '$SERVICE'"; usage ;;
esac

case "$ENV:$SERVICE" in
  prod:api) ECS_SERVICE="nexus-api-service-3y2zj6cx" ;;
  *)        echo "Error: no ECS service configured for $ENV:$SERVICE"; exit 1 ;;
esac

ECR_IMAGE="${ECR_REGISTRY}/${ECR_REPO}"

get_next_version() {
  local latest
  latest=$(aws ecr describe-images \
    --repository-name "$ECR_REPO" \
    --region "$AWS_REGION" \
    --query 'imageDetails[*].imageTags' \
    --output text 2>/dev/null \
    | tr '\t' '\n' \
    | grep -E '^v[0-9]+$' \
    | sed 's/v//' \
    | sort -n \
    | tail -1)

  if [[ -z "$latest" ]]; then
    echo "v1"
  else
    echo "v$((latest + 1))"
  fi
}

ecr_login() {
  echo "🔐 Logging in to ECR..."
  aws ecr get-login-password --region "$AWS_REGION" \
    | docker login --username AWS --password-stdin "$ECR_REGISTRY"
}

build_and_push() {
  DEPLOY_VERSION=$(get_next_version)

  echo ""
  echo "🏗️  Building and pushing ${ECR_REPO}:${DEPLOY_VERSION}..."
  echo ""

  docker buildx build \
    --platform linux/amd64 \
    -f "$DOCKERFILE" \
    -t "${ECR_IMAGE}:latest" \
    -t "${ECR_IMAGE}:${DEPLOY_VERSION}" \
    . \
    --push

  echo ""
  echo "✅ Pushed ${ECR_IMAGE}:${DEPLOY_VERSION}"
  echo "✅ Pushed ${ECR_IMAGE}:latest"
}

force_deploy() {
  echo ""
  echo "🚀 Forcing new deployment on ECS..."
  aws ecs update-service \
    --cluster "$ECS_CLUSTER" \
    --service "$ECS_SERVICE" \
    --force-new-deployment \
    --region "$AWS_REGION" \
    --no-cli-pager > /dev/null

  echo "✅ Deployment triggered: ${ECS_SERVICE} on ${ECS_CLUSTER}"
}

case "$ACTION" in
  push)
    ecr_login
    build_and_push
    force_deploy
    echo ""
    echo "🎉 Done! ${ECR_REPO}:${DEPLOY_VERSION} deployed to ${ENV}"
    ;;
  *)
    echo "Error: unknown action '$ACTION'"; usage ;;
esac
