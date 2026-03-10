#!/bin/bash
# =============================================================================
# user-data.sh.tpl - ハンズオン用 code-server 環境自動セットアップ
#
# Terraform templatefile() で以下の変数が注入される:
#   - users_json_b64    : ユーザー情報のBase64エンコードJSON配列
#   - admin_json_b64    : 管理者情報のBase64エンコードJSON (admin権限)
#   - user_start_number : ユーザー番号の開始値 (ポート計算に使用)
#   - aws_account_id    : AWSアカウントID
#   - aws_region        : AWSリージョン
#
# セットアップ状態はブラウザから確認可能:
#   https://<EC2のIP>/   → ステータスページ (セットアップ中)
#   https://<EC2のIP>/   → ユーザー一覧ページ (完了後)
# =============================================================================

set -euo pipefail
exec > >(tee /var/log/handson-setup.log) 2>&1

# ---------------------------------------------------------------------------
# 変数定義
# ---------------------------------------------------------------------------
WORK_DIR="/opt/handson"
STATUS_DIR="$${WORK_DIR}/status-page"
STATUS_FILE="$${WORK_DIR}/setup-status"
STATE_FILE="$${WORK_DIR}/setup-state"
ERROR_FILE="$${WORK_DIR}/setup-error"
USERS_JSON=$(echo "${users_json_b64}" | base64 -d)
ADMIN_JSON=$(echo "${admin_json_b64}" | base64 -d)
USER_START_NUMBER="${user_start_number}"
AWS_ACCOUNT_ID="${aws_account_id}"
AWS_REGION="${aws_region}"

mkdir -p "$${WORK_DIR}" "$${STATUS_DIR}"

# ---------------------------------------------------------------------------
# ステータス管理関数
# ---------------------------------------------------------------------------
TOTAL_STEPS=9
CURRENT_STEP=0

# ステップの状態を管理する配列（ファイルベース）
init_status() {
  echo "SETTING_UP" > "$${STATE_FILE}"
  echo "" > "$${ERROR_FILE}"
  cat > "$${STATUS_FILE}" << 'STATUSEOF'
1|pending|システムパッケージのインストール
2|pending|Swap領域の作成 (8GB)
3|pending|Dockerイメージのビルド
4|pending|自己署名TLS証明書の生成
5|pending|ユーザー設定ファイルの生成
6|pending|nginx.conf の生成
7|pending|docker-compose.yml の生成
8|pending|Docker Compose 起動
9|pending|最終確認・完了マーカー作成
STATUSEOF
  generate_status_page
}

update_step() {
  local step_num="$1"
  local status="$2"   # running, done, failed
  local detail="$${3:-}"

  # ステータスファイルを更新
  sed -i "s/^$${step_num}|[^|]*|/$${step_num}|$${status}|/" "$${STATUS_FILE}"

  # 詳細があれば追記
  if [ -n "$${detail}" ]; then
    sed -i "s|^$${step_num}|$${status}|.*|$${step_num}|$${status}|$(sed -n "s/^$${step_num}|[^|]*|//p" "$${STATUS_FILE}") ($${detail})|" "$${STATUS_FILE}" 2>/dev/null || true
  fi

  generate_status_page
}

start_step() {
  local step_num="$1"
  CURRENT_STEP=$${step_num}
  update_step "$${step_num}" "running"
  echo "[$${step_num}/$${TOTAL_STEPS}] $(sed -n "s/^$${step_num}|[^|]*|//p" "$${STATUS_FILE}") ..."
}

complete_step() {
  local step_num="$1"
  local detail="$${2:-}"
  update_step "$${step_num}" "done" "$${detail}"
  echo "[$${step_num}/$${TOTAL_STEPS}] 完了$([ -n "$${detail}" ] && echo ": $${detail}" || echo "")"
}

fail_step() {
  local step_num="$1"
  local error_msg="$2"
  update_step "$${step_num}" "failed" "$${error_msg}"
  echo "FAILED" > "$${STATE_FILE}"
  echo "$${error_msg}" > "$${ERROR_FILE}"
  echo "[$${step_num}/$${TOTAL_STEPS}] 失敗: $${error_msg}"
  generate_status_page
}

generate_status_page() {
  local state
  state=$(cat "$${STATE_FILE}" 2>/dev/null || echo "UNKNOWN")
  local error_msg
  error_msg=$(cat "$${ERROR_FILE}" 2>/dev/null || echo "")
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')

  # ステータスに応じた色とメッセージ
  local banner_color banner_text banner_icon
  case "$${state}" in
    SETTING_UP)
      banner_color="#3b82f6"
      banner_text="セットアップ進行中..."
      banner_icon="⏳"
      ;;
    READY)
      banner_color="#22c55e"
      banner_text="セットアップ完了!"
      banner_icon="✅"
      ;;
    FAILED)
      banner_color="#ef4444"
      banner_text="セットアップ失敗"
      banner_icon="❌"
      ;;
    *)
      banner_color="#6b7280"
      banner_text="状態不明"
      banner_icon="❓"
      ;;
  esac

  # ステップ一覧のHTML生成
  local steps_html=""
  while IFS='|' read -r num status desc; do
    local icon row_class
    case "$${status}" in
      done)    icon="✅"; row_class="step-done" ;;
      running) icon="⏳"; row_class="step-running" ;;
      failed)  icon="❌"; row_class="step-failed" ;;
      *)       icon="⬜"; row_class="step-pending" ;;
    esac
    steps_html="$${steps_html}<tr class=\"$${row_class}\"><td class=\"step-icon\">$${icon}</td><td class=\"step-num\">Step $${num}</td><td>$${desc}</td></tr>"
  done < "$${STATUS_FILE}"

  # エラー詳細セクション
  local error_html=""
  if [ "$${state}" = "FAILED" ] && [ -n "$${error_msg}" ]; then
    error_html="<div class=\"error-box\"><h3>❌ エラー詳細</h3><pre>$${error_msg}</pre><h4>ログの確認方法</h4><p>SSH接続が可能な場合:<br><code>ssh -i key.pem ec2-user@&lt;IP&gt; 'cat /var/log/handson-setup.log'</code></p><p>または AWS コンソール → EC2 → インスタンスを選択 → アクション → モニタリングとトラブルシューティング → システムログを取得</p></div>"
  fi

  # 自動リフレッシュ（完了またはエラー時は停止）
  local refresh_meta=""
  if [ "$${state}" = "SETTING_UP" ]; then
    refresh_meta='<meta http-equiv="refresh" content="5">'
  fi

  cat > "$${STATUS_DIR}/index.html" << HTMLEOF
<!DOCTYPE html>
<html lang="ja">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  $${refresh_meta}
  <title>ハンズオン環境セットアップ</title>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; background: #f8fafc; color: #1e293b; line-height: 1.6; }
    .container { max-width: 700px; margin: 40px auto; padding: 0 20px; }
    .banner { background: $${banner_color}; color: white; padding: 24px; border-radius: 12px; text-align: center; margin-bottom: 24px; box-shadow: 0 4px 6px rgba(0,0,0,0.1); }
    .banner h1 { font-size: 1.5rem; margin-bottom: 4px; }
    .banner .icon { font-size: 2rem; margin-bottom: 8px; }
    .banner .timestamp { font-size: 0.85rem; opacity: 0.85; }
    .card { background: white; border-radius: 12px; padding: 24px; margin-bottom: 24px; box-shadow: 0 1px 3px rgba(0,0,0,0.1); }
    .card h2 { font-size: 1.1rem; margin-bottom: 16px; color: #475569; }
    table { width: 100%; border-collapse: collapse; }
    tr { border-bottom: 1px solid #f1f5f9; }
    tr:last-child { border-bottom: none; }
    td { padding: 10px 8px; vertical-align: middle; }
    .step-icon { width: 32px; text-align: center; font-size: 1.1rem; }
    .step-num { width: 64px; font-weight: 600; color: #64748b; font-size: 0.85rem; }
    .step-done td { color: #16a34a; }
    .step-running td { color: #2563eb; font-weight: 500; }
    .step-running { background: #eff6ff; }
    .step-failed td { color: #dc2626; font-weight: 500; }
    .step-failed { background: #fef2f2; }
    .step-pending td { color: #94a3b8; }
    .error-box { background: #fef2f2; border: 1px solid #fecaca; border-radius: 8px; padding: 16px; margin-top: 16px; }
    .error-box h3 { color: #dc2626; margin-bottom: 8px; font-size: 1rem; }
    .error-box h4 { color: #991b1b; margin: 12px 0 4px; font-size: 0.9rem; }
    .error-box pre { background: #1e293b; color: #f1f5f9; padding: 12px; border-radius: 6px; overflow-x: auto; font-size: 0.8rem; white-space: pre-wrap; word-break: break-all; }
    .error-box code { background: #e2e8f0; color: #334155; padding: 2px 6px; border-radius: 4px; font-size: 0.8rem; }
    .error-box p { font-size: 0.85rem; color: #64748b; margin-top: 4px; }
    .refresh-note { text-align: center; color: #94a3b8; font-size: 0.8rem; margin-top: 8px; }
  </style>
</head>
<body>
  <div class="container">
    <div class="banner">
      <div class="icon">$${banner_icon}</div>
      <h1>$${banner_text}</h1>
      <div class="timestamp">最終更新: $${timestamp}</div>
    </div>
    <div class="card">
      <h2>セットアップ進捗</h2>
      <table>$${steps_html}</table>
      $${error_html}
    </div>
HTMLEOF

  # セットアップ中は自動リフレッシュのメモを表示
  if [ "$${state}" = "SETTING_UP" ]; then
    echo '    <p class="refresh-note">このページは5秒ごとに自動更新されます</p>' >> "$${STATUS_DIR}/index.html"
  fi

  echo '  </div></body></html>' >> "$${STATUS_DIR}/index.html"
}

# ---------------------------------------------------------------------------
# エラートラップ: 途中で失敗した場合に自動で FAILED 状態にする
# ---------------------------------------------------------------------------
on_error() {
  local exit_code=$?
  local line_no=$${1:-unknown}
  local error_msg="スクリプトが行 $${line_no} で終了コード $${exit_code} により失敗しました。"

  echo ""
  echo "=========================================="
  echo "ERROR: セットアップが失敗しました"
  echo "行: $${line_no}, 終了コード: $${exit_code}"
  echo "$(date '+%Y-%m-%d %H:%M:%S')"
  echo "=========================================="

  # 現在実行中のステップを失敗に更新
  if [ "$${CURRENT_STEP}" -gt 0 ] 2>/dev/null; then
    fail_step "$${CURRENT_STEP}" "$${error_msg}"
  else
    echo "FAILED" > "$${STATE_FILE}"
    echo "$${error_msg}" > "$${ERROR_FILE}"
    generate_status_page
  fi

  # ステータスサーバーが起動していない場合は起動する
  if ! pgrep -f "python3.*status-server" > /dev/null 2>&1; then
    start_status_server
  fi
}
trap 'on_error $LINENO' ERR

# ---------------------------------------------------------------------------
# 軽量ステータスサーバー (セットアップ中にブラウザで確認可能)
# ---------------------------------------------------------------------------
start_status_server() {
  # 既に起動していたらスキップ
  if pgrep -f "python3.*status-server" > /dev/null 2>&1; then
    return 0
  fi

  # TLS証明書がある場合はHTTPS、なければHTTP (port 443)
  if [ -f "$${WORK_DIR}/ssl/server.crt" ] && [ -f "$${WORK_DIR}/ssl/server.key" ]; then
    cat > "$${WORK_DIR}/status-server.py" << 'PYEOF'
import http.server, ssl, os, sys
os.chdir(sys.argv[1])
handler = http.server.SimpleHTTPRequestHandler
httpd = http.server.HTTPServer(("0.0.0.0", 443), handler)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(sys.argv[2], sys.argv[3])
httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
httpd.serve_forever()
PYEOF
    python3 "$${WORK_DIR}/status-server.py" \
      "$${STATUS_DIR}" \
      "$${WORK_DIR}/ssl/server.crt" \
      "$${WORK_DIR}/ssl/server.key" &
  else
    # TLS証明書がまだない場合は HTTP で仮起動
    cat > "$${WORK_DIR}/status-server.py" << 'PYEOF'
import http.server, os, sys
os.chdir(sys.argv[1])
handler = http.server.SimpleHTTPRequestHandler
httpd = http.server.HTTPServer(("0.0.0.0", 443), handler)
httpd.serve_forever()
PYEOF
    python3 "$${WORK_DIR}/status-server.py" "$${STATUS_DIR}" &
  fi
  echo "ステータスサーバー起動 (PID: $!)"
}

stop_status_server() {
  pkill -f "python3.*status-server" 2>/dev/null || true
  sleep 1
  echo "ステータスサーバー停止"
}

# ---------------------------------------------------------------------------
# セットアップ開始
# ---------------------------------------------------------------------------
echo "=========================================="
echo "ハンズオン環境セットアップ開始"
echo "$(date '+%Y-%m-%d %H:%M:%S')"
echo "=========================================="

# ステータス初期化
init_status

# ---------------------------------------------------------------------------
# 1. システムパッケージのインストール
# ---------------------------------------------------------------------------
start_step 1
dnf update -y -q
dnf install -y -q docker jq git python3

# Docker Compose (プラグイン版)
mkdir -p /usr/local/lib/docker/cli-plugins
COMPOSE_VERSION="v2.32.4"
curl -fsSL "https://github.com/docker/compose/releases/download/$${COMPOSE_VERSION}/docker-compose-linux-x86_64" \
  -o /usr/local/lib/docker/cli-plugins/docker-compose
chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

# Docker サービス起動
systemctl enable docker
systemctl start docker

complete_step 1 "Docker $(docker --version | grep -oP 'Docker version \K[^,]+')"

# ---------------------------------------------------------------------------
# 2. Swap 領域の作成 (8GB)
# ---------------------------------------------------------------------------
start_step 2
if [ ! -f /swapfile ]; then
  dd if=/dev/zero of=/swapfile bs=1M count=8192 status=none
  chmod 600 /swapfile
  mkswap /swapfile > /dev/null
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
  complete_step 2 "Swap 8GB 作成済み"
else
  complete_step 2 "Swap は既に存在 (スキップ)"
fi

# ---------------------------------------------------------------------------
# 3. Dockerfile の作成 + Docker イメージのビルド
# ---------------------------------------------------------------------------
start_step 3
cat > "$${WORK_DIR}/Dockerfile" << 'DOCKERFILE_EOF'
FROM codercom/code-server:latest

USER root

# 基本ツール
RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl wget unzip jq vim python3 python3-pip python3-venv sudo \
    && rm -rf /var/lib/apt/lists/*

# coder ユーザーに sudo 権限付与 (ハンズオン中の追加インストール用)
RUN echo "coder ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers.d/coder

# Terraform v1.14.6
RUN wget -q https://releases.hashicorp.com/terraform/1.14.6/terraform_1.14.6_linux_amd64.zip \
    -O /tmp/terraform.zip \
    && unzip -q /tmp/terraform.zip -d /usr/local/bin/ \
    && rm /tmp/terraform.zip

# AWS CLI v2
RUN curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" \
    -o /tmp/awscliv2.zip \
    && unzip -q /tmp/awscliv2.zip -d /tmp \
    && /tmp/aws/install \
    && rm -rf /tmp/awscliv2.zip /tmp/aws

# Ansible (pip)
RUN python3 -m pip install --break-system-packages ansible

# Node.js (Claude Code CLI に必要)
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# Claude Code CLI
RUN npm install -g @anthropic-ai/claude-code

USER coder
WORKDIR /home/coder/workspace
DOCKERFILE_EOF

docker build -t handson-code-server:latest "$${WORK_DIR}/"
complete_step 3 "handson-code-server:latest ビルド完了"

# ---------------------------------------------------------------------------
# 4. 自己署名TLS証明書の生成
# ---------------------------------------------------------------------------
start_step 4
mkdir -p "$${WORK_DIR}/ssl"
openssl req -x509 -nodes -days 30 -newkey rsa:2048 \
  -keyout "$${WORK_DIR}/ssl/server.key" \
  -out "$${WORK_DIR}/ssl/server.crt" \
  -subj "/CN=handson-code-server" \
  2>/dev/null
complete_step 4

# ステータスサーバーを起動 (TLS証明書が生成されたのでHTTPS対応)
start_status_server

# ---------------------------------------------------------------------------
# 5. 各ユーザーの設定ファイルを生成
# ---------------------------------------------------------------------------
start_step 5
USER_COUNT=$(echo "$${USERS_JSON}" | jq length)

for i in $(seq 0 $(($${USER_COUNT} - 1))); do
  USER_NAME=$(echo "$${USERS_JSON}" | jq -r ".[$${i}].name")
  ACCESS_KEY=$(echo "$${USERS_JSON}" | jq -r ".[$${i}].access_key")
  SECRET_KEY=$(echo "$${USERS_JSON}" | jq -r ".[$${i}].secret_key")

  # AWS credentials ディレクトリ
  CRED_DIR="$${WORK_DIR}/credentials/$${USER_NAME}/aws"
  mkdir -p "$${CRED_DIR}"

  cat > "$${CRED_DIR}/credentials" << AWSCRED_EOF
[default]
aws_access_key_id = $${ACCESS_KEY}
aws_secret_access_key = $${SECRET_KEY}
AWSCRED_EOF

  cat > "$${CRED_DIR}/config" << AWSCONF_EOF
[default]
region = $${AWS_REGION}
output = json
AWSCONF_EOF

  # Claude Code 設定ディレクトリ
  CLAUDE_DIR="$${WORK_DIR}/credentials/$${USER_NAME}/claude"
  mkdir -p "$${CLAUDE_DIR}"

  cat > "$${CLAUDE_DIR}/settings.local.json" << CLAUDE_EOF
{
    "env": {
        "CLAUDE_CODE_ENABLE_TELEMETRY": "false",
        "CLAUDE_CODE_USE_BEDROCK": "true",
        "AWS_REGION": "$${AWS_REGION}",
        "ANTHROPIC_MODEL": "arn:aws:bedrock:$${AWS_REGION}:$${AWS_ACCOUNT_ID}:inference-profile/jp.anthropic.claude-sonnet-4-6"
    }
}
CLAUDE_EOF

  # coder ユーザー (UID 1000) がコンテナ内から書き込めるようパーミッション設定
  chown -R 1000:1000 "$${WORK_DIR}/credentials/$${USER_NAME}/aws"
  chown -R 1000:1000 "$${WORK_DIR}/credentials/$${USER_NAME}/claude"
  chmod -R 755 "$${WORK_DIR}/credentials/$${USER_NAME}/claude"
done

# 管理者用の設定ファイル (admin権限)
ADMIN_ACCESS_KEY=$(echo "$${ADMIN_JSON}" | jq -r '.access_key')
ADMIN_SECRET_KEY=$(echo "$${ADMIN_JSON}" | jq -r '.secret_key')

ADMIN_CRED_DIR="$${WORK_DIR}/credentials/admin/aws"
mkdir -p "$${ADMIN_CRED_DIR}"

cat > "$${ADMIN_CRED_DIR}/credentials" << AWSCRED_EOF
[default]
aws_access_key_id = $${ADMIN_ACCESS_KEY}
aws_secret_access_key = $${ADMIN_SECRET_KEY}
AWSCRED_EOF

cat > "$${ADMIN_CRED_DIR}/config" << AWSCONF_EOF
[default]
region = $${AWS_REGION}
output = json
AWSCONF_EOF

ADMIN_CLAUDE_DIR="$${WORK_DIR}/credentials/admin/claude"
mkdir -p "$${ADMIN_CLAUDE_DIR}"

cat > "$${ADMIN_CLAUDE_DIR}/settings.local.json" << CLAUDE_EOF
{
    "env": {
        "CLAUDE_CODE_ENABLE_TELEMETRY": "false",
        "CLAUDE_CODE_USE_BEDROCK": "true",
        "AWS_REGION": "$${AWS_REGION}",
        "ANTHROPIC_MODEL": "arn:aws:bedrock:$${AWS_REGION}:$${AWS_ACCOUNT_ID}:inference-profile/jp.anthropic.claude-sonnet-4-6"
    }
}
CLAUDE_EOF

chown -R 1000:1000 "$${WORK_DIR}/credentials/admin/aws"
chown -R 1000:1000 "$${WORK_DIR}/credentials/admin/claude"
chmod -R 755 "$${WORK_DIR}/credentials/admin/claude"

complete_step 5 "$${USER_COUNT} ユーザー分 + admin"

# ---------------------------------------------------------------------------
# 6. nginx.conf の動的生成 (ポートベースルーティング)
# ---------------------------------------------------------------------------
start_step 6

# WebSocket 接続を正しくプロキシするための map ディレクティブ + ステータスページ
cat > "$${WORK_DIR}/nginx.conf" << 'NGINX_HEAD'
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen 443 ssl;
    ssl_certificate     /etc/nginx/ssl/server.crt;
    ssl_certificate_key /etc/nginx/ssl/server.key;

    location / {
        alias /usr/share/nginx/status/;
        index index.html;
    }
}
NGINX_HEAD

# 各ユーザー用サーバーブロック
for i in $(seq 0 $(($${USER_COUNT} - 1))); do
  USER_NAME=$(echo "$${USERS_JSON}" | jq -r ".[$${i}].name")
  USER_PORT=$((8000 + USER_START_NUMBER + i))

  cat >> "$${WORK_DIR}/nginx.conf" << NGINX_USER
server {
    listen $${USER_PORT} ssl;
    ssl_certificate     /etc/nginx/ssl/server.crt;
    ssl_certificate_key /etc/nginx/ssl/server.key;

    proxy_read_timeout 300s;
    proxy_send_timeout 300s;
    proxy_connect_timeout 60s;

    location / {
        proxy_pass http://code-server-$${USER_NAME}:8080/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$http_host;
        proxy_set_header Accept-Encoding gzip;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_buffering off;
    }
}
NGINX_USER
done

# 管理者用サーバーブロック (ポート 8000)
cat >> "$${WORK_DIR}/nginx.conf" << NGINX_ADMIN
server {
    listen 8000 ssl;
    ssl_certificate     /etc/nginx/ssl/server.crt;
    ssl_certificate_key /etc/nginx/ssl/server.key;

    proxy_read_timeout 300s;
    proxy_send_timeout 300s;
    proxy_connect_timeout 60s;

    location / {
        proxy_pass http://code-server-admin:8080/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$http_host;
        proxy_set_header Accept-Encoding gzip;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_buffering off;
    }
}
NGINX_ADMIN

complete_step 6 "$${USER_COUNT} ユーザー + admin のサーバーブロック生成 (ポート 8000, $((8000 + USER_START_NUMBER))-$((8000 + USER_START_NUMBER + USER_COUNT - 1)))"

# ---------------------------------------------------------------------------
# 7. docker-compose.yml の動的生成
# ---------------------------------------------------------------------------
start_step 7

# ヘッダー部分 (nginx ポートマッピング: 443 + ユーザーポート)
cat > "$${WORK_DIR}/docker-compose.yml" << COMPOSE_HEAD
services:
  nginx:
    image: nginx:alpine
    container_name: handson-nginx
    restart: unless-stopped
    ports:
      - "443:443"
COMPOSE_HEAD

# 管理者ポートマッピング
echo '      - "8000:8000"' >> "$${WORK_DIR}/docker-compose.yml"

# nginx のユーザーポートマッピングを追加
for i in $(seq 0 $(($${USER_COUNT} - 1))); do
  USER_PORT=$((8000 + USER_START_NUMBER + i))
  echo "      - \"$${USER_PORT}:$${USER_PORT}\"" >> "$${WORK_DIR}/docker-compose.yml"
done

cat >> "$${WORK_DIR}/docker-compose.yml" << 'COMPOSE_NGINX_VOL'
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - ./ssl:/etc/nginx/ssl:ro
      - ./status-page:/usr/share/nginx/status:ro
    depends_on:
COMPOSE_NGINX_VOL

# nginx の depends_on に管理者サービスを追加
echo "      code-server-admin:" >> "$${WORK_DIR}/docker-compose.yml"
echo "        condition: service_started" >> "$${WORK_DIR}/docker-compose.yml"

# nginx の depends_on にユーザーサービスを追加
for i in $(seq 0 $(($${USER_COUNT} - 1))); do
  USER_NAME=$(echo "$${USERS_JSON}" | jq -r ".[$${i}].name")
  echo "      code-server-$${USER_NAME}:" >> "$${WORK_DIR}/docker-compose.yml"
  echo "        condition: service_started" >> "$${WORK_DIR}/docker-compose.yml"
done

echo "" >> "$${WORK_DIR}/docker-compose.yml"

# 管理者用サービス定義
ADMIN_PASSWORD=$(echo "$${ADMIN_JSON}" | jq -r '.password')

cat >> "$${WORK_DIR}/docker-compose.yml" << COMPOSE_ADMIN
  code-server-admin:
    image: handson-code-server:latest
    container_name: handson-admin
    restart: unless-stopped
    environment:
      - PASSWORD=$${ADMIN_PASSWORD}
      - PREFIX=admin
      - TF_VAR_prefix=admin
    command: ["--bind-addr", "0.0.0.0:8080", "--auth", "password"]
    volumes:
      - admin-workspace:/home/coder/workspace
      - ./credentials/admin/aws:/home/coder/.aws:ro
      - ./credentials/admin/claude:/home/coder/workspace/.claude

COMPOSE_ADMIN

# 各ユーザーのサービス定義 (--base-path 不要、ルートパスで動作)
for i in $(seq 0 $(($${USER_COUNT} - 1))); do
  USER_NAME=$(echo "$${USERS_JSON}" | jq -r ".[$${i}].name")
  PASSWORD=$(echo "$${USERS_JSON}" | jq -r ".[$${i}].password")

  cat >> "$${WORK_DIR}/docker-compose.yml" << COMPOSE_SVC
  code-server-$${USER_NAME}:
    image: handson-code-server:latest
    container_name: handson-$${USER_NAME}
    restart: unless-stopped
    environment:
      - PASSWORD=$${PASSWORD}
      - PREFIX=$${USER_NAME}
      - TF_VAR_prefix=$${USER_NAME}
    command: ["--bind-addr", "0.0.0.0:8080", "--auth", "password"]
    volumes:
      - $${USER_NAME}-workspace:/home/coder/workspace
      - ./credentials/$${USER_NAME}/aws:/home/coder/.aws:ro
      - ./credentials/$${USER_NAME}/claude:/home/coder/workspace/.claude

COMPOSE_SVC
done

# volumes 定義
echo "volumes:" >> "$${WORK_DIR}/docker-compose.yml"
echo "  admin-workspace:" >> "$${WORK_DIR}/docker-compose.yml"
for i in $(seq 0 $(($${USER_COUNT} - 1))); do
  USER_NAME=$(echo "$${USERS_JSON}" | jq -r ".[$${i}].name")
  echo "  $${USER_NAME}-workspace:" >> "$${WORK_DIR}/docker-compose.yml"
done

complete_step 7

# ---------------------------------------------------------------------------
# 8. Docker Compose 起動
# ---------------------------------------------------------------------------
start_step 8

# ステータスサーバーを停止 (nginx がポート443を引き継ぐ)
stop_status_server

cd "$${WORK_DIR}"
docker compose up -d

complete_step 8 "全コンテナ起動"
docker compose ps

# ---------------------------------------------------------------------------
# 8.5 リセットスクリプトの配置
# ---------------------------------------------------------------------------
cat > "$${WORK_DIR}/reset-user.sh" << 'RESET_EOF'
#!/bin/bash
# =============================================================================
# reset-user.sh - ユーザーのワークスペースをリセット (.claude 以外を削除)
#
# コンテナを停止してから一時コンテナでクリーンアップし、再起動します。
# code-server のファイルロックやキャッシュとの競合を避けるため、
# 稼働中のコンテナに対して直接ファイル削除は行いません。
#
# 使い方:
#   sudo /opt/handson/reset-user.sh user01     # 特定ユーザーのみ
#   sudo /opt/handson/reset-user.sh admin       # 管理者環境
#   sudo /opt/handson/reset-user.sh all         # 全ユーザー (admin除く)
# =============================================================================

set -euo pipefail

COMPOSE_DIR="/opt/handson"
TARGET="$${1:-}"

if [ -z "$TARGET" ]; then
  echo "Usage: sudo $0 <username|admin|all>"
  echo ""
  echo "  例: sudo $0 user01   # user01 のワークスペースをリセット"
  echo "  例: sudo $0 admin    # 管理者環境をリセット"
  echo "  例: sudo $0 all      # 全受講者をリセット (admin除く)"
  exit 1
fi

reset_workspace() {
  local name="$1"
  local service="code-server-$${name}"

  echo "=== [$${name}] リセット開始 ==="

  echo "[$${name}] コンテナを停止中..."
  cd "$COMPOSE_DIR"
  docker compose stop "$service"

  echo "[$${name}] ワークスペースをリセット中 (.claude は保持)..."
  docker compose run --rm --no-deps -T --entrypoint sh "$service" \
    -c 'find /home/coder/workspace -mindepth 1 -maxdepth 1 ! -name ".claude" -exec rm -rf {} +'

  echo "[$${name}] コンテナを再起動中..."
  docker compose start "$service"

  echo "=== [$${name}] リセット完了 ==="
  echo ""
}

if [ "$TARGET" = "all" ]; then
  for service in $(cd "$COMPOSE_DIR" && docker compose config --services | grep '^code-server-user'); do
    name="$${service#code-server-}"
    reset_workspace "$name"
  done
else
  reset_workspace "$TARGET"
fi
RESET_EOF
chmod +x "$${WORK_DIR}/reset-user.sh"

# ---------------------------------------------------------------------------
# 8.6 ワークショップ資材更新スクリプトの配置
# ---------------------------------------------------------------------------
cat > "$${WORK_DIR}/update-materials.sh" << 'UPDATE_EOF'
#!/bin/bash
# =============================================================================
# update-materials.sh - 全コンテナのワークショップ資材を最新に更新
#
# .workshop-repo に保持した git リポジトリを pull し、ワークスペースに同期します。
# ユーザーが作成したファイル (.env, terraform/, ansible/, keys/) は上書きしません。
# コンテナの再起動は不要です。
#
# 使い方:
#   sudo /opt/handson/update-materials.sh          # 全コンテナ
#   sudo /opt/handson/update-materials.sh user01   # 特定ユーザーのみ
# =============================================================================

set -euo pipefail

COMPOSE_DIR="/opt/handson"
TARGET="$${1:-all}"
REPO_URL="https://github.com/kifujii/ai_agentic_development.git"

sync_materials() {
  local container="$1"
  local name="$${container#handson-}"

  echo "=== [$${name}] 資材更新中 ==="
  docker exec "$container" bash -c '
    REPO_DIR="/home/coder/.workshop-repo"
    WORKSPACE="/home/coder/workspace"
    REPO_URL="https://github.com/kifujii/ai_agentic_development.git"

    if [ -d "$REPO_DIR/.git" ]; then
      git -C "$REPO_DIR" pull --ff-only 2>/dev/null || true
    else
      git clone --depth 1 "$REPO_URL" "$REPO_DIR" 2>/dev/null || true
    fi

    if [ -d "$REPO_DIR" ]; then
      cd "$REPO_DIR"
      tar cf - \
        --exclude=".git" \
        --exclude=".env" \
        --exclude="terraform" \
        --exclude="ansible" \
        --exclude="keys" \
        . | tar xf - -C "$WORKSPACE/" 2>/dev/null || true
    fi
  '
  echo "=== [$${name}] 更新完了 ==="
}

cd "$COMPOSE_DIR"

if [ "$TARGET" = "all" ]; then
  for container in $(docker compose ps --format '{{.Name}}' | grep handson-); do
    sync_materials "$container"
  done
else
  sync_materials "handson-$TARGET"
fi

echo ""
echo "資材更新が完了しました"
UPDATE_EOF
chmod +x "$${WORK_DIR}/update-materials.sh"

# ---------------------------------------------------------------------------
# 8.7 ワークショップ資材の事前配置
# ---------------------------------------------------------------------------
start_step "8.7"

# ワークスペース初期化スクリプトをホストに作成
cat > "$${WORK_DIR}/init-workspace.sh" << 'INITWS_EOF'
#!/bin/bash
set -e
USER_PREFIX="$1"
WORKSPACE="/home/coder/workspace"
REPO_DIR="/home/coder/.workshop-repo"
REPO_URL="https://github.com/kifujii/ai_agentic_development.git"

# ワークショップ資材のクローン/更新 (.workshop-repo に保持)
if [ -d "$REPO_DIR/.git" ]; then
  git -C "$REPO_DIR" pull --ff-only 2>/dev/null || true
else
  git clone --depth 1 "$REPO_URL" "$REPO_DIR" 2>/dev/null || true
fi

# 資材をワークスペースにコピー (ユーザーが作成するデータは保護)
if [ -d "$REPO_DIR" ]; then
  cd "$REPO_DIR"
  tar cf - \
    --exclude='.git' \
    --exclude='.env' \
    --exclude='terraform' \
    --exclude='ansible' \
    --exclude='keys' \
    . | tar xf - -C "$WORKSPACE/" 2>/dev/null || true
fi

cd "$WORKSPACE"

# .env の作成 (PREFIX を自動設定)
if [ -f ".env.template" ] && [ ! -f ".env" ]; then
  sed "s/PREFIX=user01/PREFIX=$USER_PREFIX/" .env.template > .env
fi

# 作業ディレクトリの作成
mkdir -p "$WORKSPACE/terraform" "$WORKSPACE/ansible" "$WORKSPACE/keys"

# ~/.bashrc に .env 自動読み込みとエイリアスを追加
if ! grep -q ".envファイルを自動的に読み込む" ~/.bashrc 2>/dev/null; then
  cat >> ~/.bashrc << 'BASHRC_APPEND'

# .envファイルを自動的に読み込む
if [ -f "/home/coder/workspace/.env" ]; then
  set -a
  source "/home/coder/workspace/.env"
  set +a
  [ -n "$${PREFIX:-}" ] && export TF_VAR_prefix="$PREFIX"
fi

# エイリアス
alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'
alias ..='cd ..'
alias ...='cd ../..'
alias tf='terraform'
alias tfi='terraform init'
alias tfp='terraform plan'
alias tfa='terraform apply'
alias tfd='terraform destroy'
alias ap='ansible-playbook'
BASHRC_APPEND
fi

# Claude Code オンボーディングスキップ
CLAUDE_GLOBAL="/home/coder/.claude"
CLAUDE_CFG="$CLAUDE_GLOBAL/claude.json"
mkdir -p "$CLAUDE_GLOBAL"
if [ -f "$CLAUDE_CFG" ]; then
  jq '.hasCompletedOnboarding = true | .hasTrustDialogHooksAccepted = true' \
    "$CLAUDE_CFG" > "$CLAUDE_CFG.tmp" && mv "$CLAUDE_CFG.tmp" "$CLAUDE_CFG"
else
  echo '{"hasCompletedOnboarding":true,"hasTrustDialogHooksAccepted":true}' > "$CLAUDE_CFG"
fi
INITWS_EOF
chmod +x "$${WORK_DIR}/init-workspace.sh"

# 各ユーザーのワークスペースを初期化
for i in $(seq 0 $(($${USER_COUNT} - 1))); do
  USER_NAME=$(echo "$${USERS_JSON}" | jq -r ".[$${i}].name")
  CONTAINER="handson-$${USER_NAME}"

  echo "[$${USER_NAME}] ワークスペース初期化中..."
  docker cp "$${WORK_DIR}/init-workspace.sh" "$${CONTAINER}:/tmp/init-workspace.sh"
  docker exec "$${CONTAINER}" bash /tmp/init-workspace.sh "$${USER_NAME}" || {
    echo "警告: $${USER_NAME} のワークスペース初期化に失敗しました"
  }
done

# 管理者環境も初期化
echo "[admin] ワークスペース初期化中..."
docker cp "$${WORK_DIR}/init-workspace.sh" "handson-admin:/tmp/init-workspace.sh"
docker exec "handson-admin" bash /tmp/init-workspace.sh "admin" || {
  echo "警告: admin のワークスペース初期化に失敗しました"
}

complete_step "8.7" "ワークショップ資材を $${USER_COUNT} ユーザー + admin に配置"

# ---------------------------------------------------------------------------
# 9. 最終確認・完了マーカー作成
# ---------------------------------------------------------------------------
start_step 9

# 全コンテナが起動しているか確認
RUNNING_COUNT=$(docker compose ps --status running -q 2>/dev/null | wc -l)
EXPECTED_COUNT=$(($${USER_COUNT} + 2))  # code-server x N + admin + nginx

if [ "$${RUNNING_COUNT}" -lt "$${EXPECTED_COUNT}" ]; then
  echo "警告: 起動コンテナ数 ($${RUNNING_COUNT}) が期待値 ($${EXPECTED_COUNT}) より少ないです"
  echo "停止中のコンテナ:"
  docker compose ps --status exited 2>/dev/null || true
fi

# 完了マーカー作成
touch "$${WORK_DIR}/setup-complete"

# ステータスを READY に更新
echo "READY" > "$${STATE_FILE}"
complete_step 9 "コンテナ $${RUNNING_COUNT}/$${EXPECTED_COUNT} 起動中"

# 最終ステータスページを再生成
generate_status_page

echo ""
echo "=========================================="
echo "ハンズオン環境セットアップ完了!"
echo "$(date '+%Y-%m-%d %H:%M:%S')"
echo "=========================================="
echo ""
echo "コンテナ数: $(($${USER_COUNT} + 1)) ($${USER_COUNT} ユーザー + admin)"
echo "Admin: https://<PUBLIC_IP>:8000/"
echo "参加者: https://<PUBLIC_IP>:800X/ (ポート $((8000 + USER_START_NUMBER))〜$((8000 + USER_START_NUMBER + USER_COUNT - 1)))"
echo "ステータス: https://<PUBLIC_IP>/"
