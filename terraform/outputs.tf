################################################################################
# outputs.tf - 参加者配布情報 + 管理者用情報
################################################################################

output "ec2_public_ip" {
  description = "EC2 インスタンスの固定パブリックIP (Elastic IP)"
  value       = aws_eip.handson.public_ip
}

output "credentials_sheet" {
  description = "参加者配布用の URL + パスワード一覧"
  value = [for i in range(var.user_count) : {
    user     = format("user%02d", i + 1)
    url      = format("https://%s:%d/", aws_eip.handson.public_ip, 8001 + i)
    password = random_password.code_server[i].result
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
