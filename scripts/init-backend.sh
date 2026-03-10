#!/bin/bash
# =============================================================================
# init-backend.sh - S3バケット作成 + Terraform初期化
#
# 使い方:
#   source .env
#   ./scripts/init-backend.sh
#
# 環境変数:
#   TF_STATE_BUCKET (必須) - Terraform state を保存する S3 バケット名
#   TF_VAR_aws_region      - AWS リージョン (デフォルト: ap-northeast-1)
#   TF_VAR_project_name    - ステートファイルのキープレフィックス (デフォルト: handson)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TERRAFORM_DIR="${SCRIPT_DIR}/../terraform"

BUCKET="${TF_STATE_BUCKET:-}"
REGION="${TF_VAR_aws_region:-ap-northeast-1}"
PROJECT="${TF_VAR_project_name:-handson}"
STATE_KEY="${PROJECT}/terraform.tfstate"

if [ -z "$BUCKET" ]; then
  echo "エラー: TF_STATE_BUCKET が設定されていません"
  echo "  .env に TF_STATE_BUCKET を設定してから source .env を実行してください"
  exit 1
fi

echo "=== Terraform バックエンド初期化 ==="
echo "  バケット: ${BUCKET}"
echo "  キー:     ${STATE_KEY}"
echo "  リージョン: ${REGION}"
echo ""

# S3 バケットの作成 (存在しない場合のみ)
if aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  echo "S3 バケットは既に存在します: ${BUCKET}"
else
  echo "S3 バケットを作成します: ${BUCKET}"

  if [ "$REGION" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "$BUCKET"
  else
    aws s3api create-bucket --bucket "$BUCKET" \
      --create-bucket-configuration LocationConstraint="$REGION"
  fi

  aws s3api put-bucket-versioning --bucket "$BUCKET" \
    --versioning-configuration Status=Enabled

  aws s3api put-bucket-encryption --bucket "$BUCKET" \
    --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

  aws s3api put-public-access-block --bucket "$BUCKET" \
    --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

  echo "S3 バケットを作成しました (バージョニング有効・暗号化有効・パブリックアクセスブロック済み)"
fi

echo ""
echo "=== terraform init ==="

cd "$TERRAFORM_DIR"
terraform init \
  -backend-config="bucket=${BUCKET}" \
  -backend-config="key=${STATE_KEY}" \
  -backend-config="region=${REGION}" \
  -backend-config="encrypt=true"

echo ""
echo "=== 初期化完了 ==="
echo "次のステップ: cd terraform && terraform apply"
