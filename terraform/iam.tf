################################################################################
# iam.tf - IAMユーザー x N + アクセスキー + ポリシー
################################################################################

# code-server のパスワード (ユーザーごとに自動生成)
resource "random_password" "code_server" {
  count   = var.user_count
  length  = 10
  special = false
}

# AWSコンソールログイン用パスワード (ユーザーごとに自動生成)
# min_upper/min_lower/min_numeric で一般的なパスワードポリシーを満たす
resource "random_password" "console" {
  count       = var.user_count
  length      = 12
  special     = false
  min_upper   = 2
  min_lower   = 2
  min_numeric = 2
}

# 管理者用 code-server のパスワード
resource "random_password" "admin" {
  length  = 16
  special = false
}

################################################################################
# IAM ユーザー
################################################################################

resource "aws_iam_user" "handson" {
  count = var.user_count
  name  = format("${var.project_name}-user%02d", count.index + var.user_start_number)
  path  = "/${var.project_name}/"

  tags = {
    Name    = format("${var.project_name}-user%02d", count.index + var.user_start_number)
    Purpose = "handson"
  }
}

# プログラムアクセス用のアクセスキー
resource "aws_iam_access_key" "handson" {
  count = var.user_count
  user  = aws_iam_user.handson[count.index].name
}

# AWSコンソールログイン用パスワード設定
# aws_iam_user_login_profile の password 属性は AWS Provider v5 で廃止のため
# null_resource + local-exec で aws iam create-login-profile を直接呼び出す
resource "null_resource" "console_login" {
  count = var.user_count

  triggers = {
    user_name = aws_iam_user.handson[count.index].name
    password  = random_password.console[count.index].result
  }

  provisioner "local-exec" {
    command = <<EOT
if aws iam get-login-profile --user-name '${aws_iam_user.handson[count.index].name}' 2>/dev/null; then
  aws iam update-login-profile \
    --user-name '${aws_iam_user.handson[count.index].name}' \
    --password '${random_password.console[count.index].result}' \
    --no-password-reset-required
else
  aws iam create-login-profile \
    --user-name '${aws_iam_user.handson[count.index].name}' \
    --password '${random_password.console[count.index].result}' \
    --no-password-reset-required
fi
EOT
  }
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
        Sid    = "MarketplaceForBedrock"
        Effect = "Allow"
        Action = [
          "aws-marketplace:ViewSubscriptions",
          "aws-marketplace:Subscribe"
        ]
        Resource = "*"
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
          "iam:GetInstanceProfile",
          "iam:ListRoles",
          "iam:ListAttachedRolePolicies",
          "iam:ListRolePolicies",
          "iam:ListInstanceProfiles",
          "iam:ListInstanceProfilesForRole",
          "iam:CreateRole",
          "iam:DeleteRole",
          "iam:TagRole",
          "iam:AttachRolePolicy",
          "iam:DetachRolePolicy",
          "iam:CreateInstanceProfile",
          "iam:DeleteInstanceProfile",
          "iam:TagInstanceProfile",
          "iam:AddRoleToInstanceProfile",
          "iam:RemoveRoleFromInstanceProfile"
        ]
        Resource = "*"
      },
      {
        Sid    = "SSMAccess"
        Effect = "Allow"
        Action = [
          "ssm:DescribeInstanceInformation",
          "ssm:SendCommand",
          "ssm:ListCommands",
          "ssm:ListCommandInvocations",
          "ssm:GetCommandInvocation",
          "ssm:StartSession",
          "ssm:TerminateSession",
          "ssm:DescribeSessions",
          "ssm:GetConnectionStatus"
        ]
        Resource = "*"
      },
      {
        Sid    = "CloudWatchAccess"
        Effect = "Allow"
        Action = [
          "cloudwatch:PutMetricAlarm",
          "cloudwatch:DescribeAlarms",
          "cloudwatch:DeleteAlarms",
          "cloudwatch:ListMetrics",
          "cloudwatch:GetMetricData",
          "cloudwatch:GetMetricStatistics",
          "cloudwatch:PutMetricData"
        ]
        Resource = "*"
      },
      {
        Sid    = "CloudWatchLogsAccess"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams",
          "logs:GetLogEvents",
          "logs:PutRetentionPolicy",
          "logs:DeleteLogGroup",
          "logs:DeleteLogStream"
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
