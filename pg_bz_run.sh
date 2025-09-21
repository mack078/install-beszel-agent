#!/bin/bash
set -e

BASE_DIR="/opt/beszel-agent"
DATA_DIR="$BASE_DIR/data"
START_SCRIPT="$DATA_DIR/start-agent.sh"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"

# ⚙️ 配置參數 (請改成你自己的 Hub)
HUB_URL="http://43.128.60.111:8090"
LISTEN="45876"
TOKEN="ef517673-d9b3-4685-b1a6-fb47325d8dd1"   # 通用令牌，有效期 1 小時

echo "🚀 開始安裝 Beszel Agent..."

# 0. 檢查 Docker 是否安裝
if ! command -v docker &> /dev/null; then
  echo "⚠️ 系統尚未安裝 Docker，開始安裝..."

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
      # 👉 使用阿里雲鏡像源 (解決官方源無法訪問問題)
      tee /etc/yum.repos.d/docker-ce.repo <<-'EOF'
[docker-ce-stable]
name=Docker CE Stable - $basearch
baseurl=https://mirrors.aliyun.com/docker-ce/linux/centos/7/$basearch/stable
enabled=1
gpgcheck=1
gpgkey=https://mirrors.aliyun.com/docker-ce/linux/centos/gpg
EOF
      yum makecache fast
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

# 0.1 檢查 docker compose
if ! docker compose version &> /dev/null; then
  echo "⚠️ 沒有 docker compose plugin，開始安裝..."
  DOCKER_CONFIG=${DOCKER_CONFIG:-$HOME/.docker}
  mkdir -p $DOCKER_CONFIG/cli-plugins
  curl -SL https://github.com/docker/compose/releases/download/v2.29.7/docker-compose-$(uname -s)-$(uname -m) \
    -o $DOCKER_CONFIG/cli-plugins/docker-compose
  chmod +x $DOCKER_CONFIG/cli-plugins/docker-compose
  echo "✅ docker compose 安裝完成"
else
  echo "✅ docker compose 已安裝"
fi

# 1. 建立資料目錄
mkdir -p "$DATA_DIR"

# 2. 建立 start-agent.sh
cat > "$START_SCRIPT" << 'EOF'
#!/bin/sh
DATA_DIR="/var/lib/beszel-agent"
FINGERPRINT_FILE="$DATA_DIR/fingerprint.txt"
LOG_FILE="$DATA_DIR/agent.log"

start_with_fingerprint() {
  echo "✅ 使用 Fingerprint 啟動"
  exec /beszel-agent --hub-url $HUB_URL --fingerprint $(cat $FINGERPRINT_FILE)
}

start_with_token() {
  echo "🔑 使用 TOKEN 註冊..."
  /beszel-agent --hub-url $HUB_URL --token $TOKEN > $LOG_FILE 2>&1 &
  AGENT_PID=$!

  sleep 6
  FINGERPRINT=$(grep "fingerprint" $LOG_FILE | tail -n1 | awk '{print $NF}')

  if [ -n "$FINGERPRINT" ]; then
    echo $FINGERPRINT > $FINGERPRINT_FILE
    echo "✅ Fingerprint 已保存：$FINGERPRINT"
  else
    echo "❌ 沒擷取到 Fingerprint，請檢查日誌：$LOG_FILE"
  fi

  kill $AGENT_PID || true
  sleep 2
  start_with_fingerprint
}

# --- 主流程 ---
if [ -f "$FINGERPRINT_FILE" ]; then
  echo "📂 檢測到 Fingerprint，嘗試登入..."
  /beszel-agent --hub-url $HUB_URL --fingerprint $(cat $FINGERPRINT_FILE) > $LOG_FILE 2>&1 &
  AGENT_PID=$!
  sleep 8
  if grep -q "fingerprint mismatch" $LOG_FILE; then
    echo "⚠️ fingerprint mismatch，刪除並重新註冊..."
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
cat > "$COMPOSE_FILE" << EOF
services:
  beszel-agent:
    image: henrygd/beszel-agent
    container_name: beszel-agent
    restart: unless-stopped
    network_mode: host
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - $DATA_DIR:/var/lib/beszel-agent
    environment:
      LISTEN: $LISTEN
      TOKEN: $TOKEN
      HUB_URL: $HUB_URL
    command: ["/bin/sh", "/var/lib/beszel-agent/start-agent.sh"]
EOF

echo "📝 已建立 $COMPOSE_FILE"

# 4. 啟動服務
docker compose -f "$COMPOSE_FILE" down || true
docker compose -f "$COMPOSE_FILE" up -d

echo "✅ Beszel Agent 已安裝並啟動完成！"
echo "📂 目錄: $BASE_DIR"
echo "📂 指紋 & 日誌: $DATA_DIR"
