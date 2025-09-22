#!/bin/bash
set -e

BASE_DIR="/opt/beszel-agent"
DATA_DIR="$BASE_DIR/data"
START_SCRIPT="$DATA_DIR/start-agent.sh"
COMPOSE_FILE="$BASE_DIR/docker-compose.yml"

# ⚙️ 配置參數 (請改成你自己的 Hub)
HUB_URL="http://43.128.60.111:8090"
LISTEN="45876"
TOKEN="72a9f592-d4ca-4cc8-a34a-46a376fdd00c"   # 通用令牌，有效期 1 小時
KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIO9ktQKLXyOAI9V0BLFQAR+MU7/BbSPQ6bOOOgGTVs6x"

# 主鏡像 & 備用阿里雲鏡像
IMAGE_MAIN="henrygd/beszel-agent:latest"
IMAGE_MIRROR="registry.cn-hongkong.aliyuncs.com/mackrepo/beszel-agent:latest"

echo "🚀 開始安裝 Beszel Agent..."

# ---------------- Docker 安裝 (略，跟之前相同) ----------------
# 我省略重複的安裝/加速器/compose 檢查邏輯，保持不變

# ---------------- 資料目錄 ----------------
mkdir -p "$DATA_DIR"

# ---------------- start-agent.sh ----------------
cat > "$START_SCRIPT" << 'EOF'
#!/bin/sh
# 匯出環境變數，避免 agent 啟動找不到
export HUB_URL=$HUB_URL
export TOKEN=$TOKEN
export KEY=$KEY

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

# ---------------- 嘗試拉取鏡像 ----------------
echo "📥 嘗試拉取 $IMAGE_MAIN ..."
if ! docker pull $IMAGE_MAIN; then
  echo "⚠️ 無法拉取 $IMAGE_MAIN，改用阿里雲鏡像 $IMAGE_MIRROR"
  docker pull $IMAGE_MIRROR
  docker tag $IMAGE_MIRROR $IMAGE_MAIN
fi

# ---------------- docker-compose.yml ----------------
cat > "$COMPOSE_FILE" << EOF
services:
  beszel-agent:
    image: $IMAGE_MAIN
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
      KEY: $KEY
    command: ["/bin/sh", "/var/lib/beszel-agent/start-agent.sh"]
EOF

echo "📝 已建立 $COMPOSE_FILE"

# ---------------- 啟動 ----------------
docker compose -f "$COMPOSE_FILE" down || true
docker compose -f "$COMPOSE_FILE" up -d

echo "✅ Beszel Agent 已安裝並啟動完成！"
echo "📂 目錄: $BASE_DIR"
echo "📂 指紋 & 日誌: $DATA_DIR"
