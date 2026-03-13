################################################################################
# outputs.tf - 参加者配布情報 + 管理者用情報
################################################################################

output "ec2_public_ip" {
  description = "EC2 インスタンスの固定パブリックIP (Elastic IP)"
  value       = aws_eip.handson.public_ip
}

output "credentials_sheet" {
  description = "参加者配布用の URL + パスワード一覧 (code-server + AWSコンソール)"
  value = [for i in range(var.user_count) : {
    user              = format("user%02d", i + var.user_start_number)
    url               = format("https://%s:%d/", aws_eip.handson.public_ip, 8000 + var.user_start_number + i)
    password          = random_password.code_server[i].result
    console_login_url = "https://${data.aws_caller_identity.current.account_id}.signin.aws.amazon.com/console"
    console_user      = format("${var.project_name}-user%02d", i + var.user_start_number)
    console_password  = random_password.console[i].result
  }]
  sensitive = true
}

output "ssh_private_key" {
  description = "管理者SSH用の秘密鍵 (terraform output -raw ssh_private_key > key.pem)"
  value       = tls_private_key.ssh.private_key_pem
  sensitive   = true
}

output "ssh_command" {
  description = "SSH接続コマンド例 (admin_cidr 設定時のみ使用可能)"
  value       = var.admin_cidr != "" ? "ssh -i key.pem ec2-user@${aws_eip.handson.public_ip}" : "SSHアクセスは無効です (admin_cidr が未設定)"
}

output "admin_url" {
  description = "管理者用 code-server の URL (admin権限)"
  value       = "https://${aws_eip.handson.public_ip}:8000/"
}

output "admin_password" {
  description = "管理者用 code-server のパスワード"
  value       = random_password.admin.result
  sensitive   = true
}

output "reset_user_command" {
  description = "ユーザーのワークスペースをリセットするコマンド例 (admin_cidr 設定時のみ使用可能)"
  value       = var.admin_cidr != "" ? "ssh -i key.pem ec2-user@${aws_eip.handson.public_ip} 'sudo /opt/handson/reset-user.sh <username>'" : "SSHアクセスは無効です (admin_cidr が未設定)"
}

output "update_materials_command" {
  description = "ワークショップ資材を最新に更新するコマンド (admin_cidr 設定時のみ使用可能)"
  value       = var.admin_cidr != "" ? "ssh -i key.pem ec2-user@${aws_eip.handson.public_ip} 'sudo /opt/handson/update-materials.sh'" : "SSHアクセスは無効です (admin_cidr が未設定)"
}

output "setup_status_url" {
  description = "セットアップ状況確認URL (ブラウザで開く)"
  value       = "https://${aws_eip.handson.public_ip}/"
}

output "setup_status_command" {
  description = "セットアップ完了確認コマンド (admin_cidr 設定時のみ使用可能)"
  value       = var.admin_cidr != "" ? "ssh -i key.pem ec2-user@${aws_eip.handson.public_ip} 'cat /opt/handson/setup-state'" : "SSHアクセスは無効です (admin_cidr が未設定)。ブラウザで https://${aws_eip.handson.public_ip}/status/ を確認してください。"
}

output "setup_log_command" {
  description = "セットアップログ確認コマンド (admin_cidr 設定時のみ使用可能)"
  value       = var.admin_cidr != "" ? "ssh -i key.pem ec2-user@${aws_eip.handson.public_ip} 'cat /var/log/handson-setup.log'" : "SSHアクセスは無効です (admin_cidr が未設定)"
}
