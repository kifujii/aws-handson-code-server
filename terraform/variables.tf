################################################################################
# variables.tf - ハンズオン環境の設定変数
################################################################################

variable "user_count" {
  description = "ハンズオン参加者数"
  type        = number
  default     = 20
}

variable "user_start_number" {
  description = "ユーザー番号の開始値 (例: 1→user01〜, 11→user11〜)。複数環境でユーザーを分ける場合に使用"
  type        = number
  default     = 1
}

variable "admin_cidr" {
  description = "管理者のSSHアクセス元CIDR。未設定=SSH無効 / IPアドレス/32=IP限定 / 0.0.0.0/0=フルオープン(検証用)"
  type        = string
  default     = ""
}

variable "aws_region" {
  description = "AWSリージョン"
  type        = string
  default     = "ap-northeast-1"
}

variable "instance_type" {
  description = "EC2インスタンスタイプ"
  type        = string
  default     = "m6i.8xlarge"
}

variable "volume_size" {
  description = "EBSボリュームサイズ (GB)"
  type        = number
  default     = 300
}

variable "project_name" {
  description = "プロジェクト名 (リソースのNameタグに使用)"
  type        = string
  default     = "handson"
}

variable "admin_access_key" {
  description = "管理者用code-server環境のAWSアクセスキー (AdministratorAccess相当)"
  type        = string
  sensitive   = true
}

variable "admin_secret_key" {
  description = "管理者用code-server環境のAWSシークレットキー"
  type        = string
  sensitive   = true
}
