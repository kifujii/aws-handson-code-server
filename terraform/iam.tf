################################################################################
# iam.tf - IAMユーザー x N + アクセスキー + ポリシー
################################################################################

# code-server のパスワード (ユーザーごとに自動生成)
resource "random_password" "code_server" {
  count   = var.user_count
  length  = 10
  special = false
}

################################################################################
# IAM ユーザー
################################################################################

resource "aws_iam_user" "handson" {
  count = var.user_count
  name  = format("${var.project_name}-user%02d", count.index + 1)
  path  = "/${var.project_name}/"

  tags = {
    Name    = format("${var.project_name}-user%02d", count.index + 1)
    Purpose = "handson"
  }
}

# コンソールアクセスは無効 (aws_iam_user_login_profile を作成しない)
# プログラムアクセス用のアクセスキーのみ発行
resource "aws_iam_access_key" "handson" {
  count = var.user_count
  user  = aws_iam_user.handson[count.index].name
}

################################################################################
# IAM ポリシー
################################################################################

resource "aws_iam_policy" "handson" {
  name        = "${var.project_name}-policy"
  path        = "/${var.project_name}/"
  description = "Handson participants policy - Bedrock, EC2/VPC, limited IAM"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "BedrockInvoke"
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream"
        ]
        Resource = [
          "arn:aws:bedrock:*::foundation-model/anthropic.*",
          "arn:aws:bedrock:*:*:inference-profile/*"
        ]
      },
      {
        Sid      = "EC2AndVPC"
        Effect   = "Allow"
        Action   = "ec2:*"
        Resource = "*"
      },
      {
        Sid    = "IAMForEC2"
        Effect = "Allow"
        Action = [
          "iam:PassRole",
          "iam:GetRole",
          "iam:ListRoles",
          "iam:CreateRole",
          "iam:AttachRolePolicy",
          "iam:DetachRolePolicy",
          "iam:DeleteRole",
          "iam:ListInstanceProfiles",
          "iam:CreateInstanceProfile",
          "iam:DeleteInstanceProfile",
          "iam:AddRoleToInstanceProfile",
          "iam:RemoveRoleFromInstanceProfile"
        ]
        Resource = "*"
      },
      {
        Sid      = "STSIdentity"
        Effect   = "Allow"
        Action   = "sts:GetCallerIdentity"
        Resource = "*"
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-policy"
  }
}

# 全ユーザーにポリシーをアタッチ
resource "aws_iam_user_policy_attachment" "handson" {
  count      = var.user_count
  user       = aws_iam_user.handson[count.index].name
  policy_arn = aws_iam_policy.handson.arn
}
