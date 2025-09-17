#!/bin/bash
set -e

BASE_DIR="/opt/beszel-agent"
DATA_DIR="$BASE_DIR/data"
START_SCRIPT="$DATA_DIR/start-agent.sh"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"

echo "🚀 開始安裝 Beszel Agent..."

# 0. 檢查 Docker 是否安裝
if ! command -v docker &> /dev/null; then
  echo "⚠️ 系統尚未安裝 Docker，開始安裝..."

  # 判斷作業系統
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
  else
    echo "❌ 無法識別系統版本，請手動安裝 Docker"
    exit 1
  fi

  case "$OS" in
    ubuntu|debian)
      apt-get update
      apt-get install -y ca-certificates curl gnupg lsb-release
      install -m 0755 -d /etc/apt/keyrings
      curl -fsSL https://download.docker.com/linux/$OS/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
      chmod a+r /etc/apt/keyrings/docker.gpg
      echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$OS \
        $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
      apt-get update
      apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
      ;;
    centos|rhel|rocky|almalinux)
      yum install -y yum-utils
      yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
      yum install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
      systemctl enable docker
      systemctl start docker
      ;;
    *)
      echo "❌ 暫不支援的系統: $OS"
      exit 1
      ;;
  esac

  echo "✅ Docker 安裝完成"
else
  echo "✅ Docker 已安裝"
fi

# 0.1 檢查 docker compose 是否可用
if ! docker compose version &> /dev/null; then
  echo "⚠️ 系統沒有安裝 docker compose plugin，開始安裝..."
  DOCKER_CONFIG=${DOCKER_CONFIG:-$HOME/.docker}
  mkdir -p $DOCKER_CONFIG/cli-plugins
  curl -SL https://github.com/docker/compose/releases/download/v2.29.7/docker-compose-$(uname -s)-$(uname -m) \
    -o $DOCKER_CONFIG/cli-plugins/docker-compose
  chmod +x $DOCKER_CONFIG/cli-plugins/docker-compose
  echo "✅ docker compose 安裝完成"
else
  echo "✅ docker compose 已安裝"
fi

# 1. 建立主目錄並切換
mkdir -p "$BASE_DIR"
cd "$BASE_DIR"
mkdir -p "$DATA_DIR"

# 2. 建立新版 start-agent.sh（含 fingerprint mismatch 自動修復）
cat > "$START_SCRIPT" << 'EOF'
#!/bin/sh
DATA_DIR="/var/lib/beszel-agent"
FINGERPRINT_FILE="$DATA_DIR/fingerprint.txt"
LOG_FILE="$DATA_DIR/agent.log"

start_with_fingerprint() {
  echo "✅ 使用 Fingerprint 啟動代理程式"
  exec /beszel-agent --hub-url $HUB_URL --fingerprint $(cat $FINGERPRINT_FILE)
}

start_with_token() {
  echo "🔑 使用 TOKEN 註冊代理程式..."
  /beszel-agent --hub-url $HUB_URL --token $TOKEN > $LOG_FILE 2>&1 &

  # 等待 fingerprint 輸出
  sleep 5
  FINGERPRINT=$(grep "fingerprint" $LOG_FILE | tail -n1 | awk '{print $NF}')

  if [ -n "$FINGERPRINT" ]; then
    echo $FINGERPRINT > $FINGERPRINT_FILE
    echo "✅ Fingerprint 已保存：$FINGERPRINT"
  else
    echo "❌ 沒能自動擷取 Fingerprint，請檢查日誌：$LOG_FILE"
  fi

  # 停掉臨時代理程式
  pkill -f /beszel-agent || true
  sleep 2

  start_with_fingerprint
}

# --- 主流程 ---
if [ -f "$FINGERPRINT_FILE" ]; then
  echo "📂 檢測到 Fingerprint 檔案，嘗試使用 Fingerprint 登入..."
  /beszel-agent --hub-url $HUB_URL --fingerprint $(cat $FINGERPRINT_FILE) > $LOG_FILE 2>&1 &
  AGENT_PID=$!

  sleep 8
  if grep -q "fingerprint mismatch" $LOG_FILE; then
    echo "⚠️ 偵測到 fingerprint mismatch，刪除 fingerprint.txt 並重新註冊..."
    rm -f $FINGERPRINT_FILE
    kill $AGENT_PID || true
    sleep 2
    start_with_token
  else
    wait $AGENT_PID
  fi
else
  start_with_token
fi
EOF

chmod +x "$START_SCRIPT"
echo "📝 已建立 $START_SCRIPT"

# 3. 建立 docker-compose.yml
cat > "$COMPOSE_FILE" << 'EOF'
services:
  beszel-agent:
    image: henrygd/beszel-agent
    container_name: beszel-agent
    restart: unless-stopped
    network_mode: host
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - /opt/beszel-agent/data:/var/lib/beszel-agent
    environment:
      LISTEN: 45876
      KEY: 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGDwxFoRjuu9YCkS225AqOB7Q1xnd5iG+6cFcrtB3tgn'
      TOKEN: 2b139e35-8600-4613-908d-7e3fbe3849d5
      HUB_URL: http://139.162.10.239:8090/
    command: ["/bin/sh", "/var/lib/beszel-agent/start-agent.sh"]
EOF

echo "📝 已建立 $COMPOSE_FILE"

# 4. 啟動 docker compose
docker compose down || true
docker compose up -d

echo "✅ Beszel Agent 已安裝並啟動完成！"
echo "📂 主目錄: $BASE_DIR"
echo "📂 指紋 & 日誌儲存: $DATA_DIR"
echo "📂 啟動腳本: $START_SCRIPT"
