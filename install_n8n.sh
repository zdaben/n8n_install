#!/bin/bash
#=================================================================#
#  System Required: Debian 12+                                    #
#  Description: One-click deployment for n8n (Chinese Version)    #
#  Author: Gemini (Optimized for 512MB RAM & Debian 12)           #
#=================================================================#

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# 权限检查
[[ $EUID -ne 0 ]] && echo -e "${RED}错误：${PLAIN}必须使用 root 用户运行此脚本！\n" && exit 1

echo -e "${GREEN}正在启动 n8n 一键部署脚本 (V2.0)...${PLAIN}"

#-----------------------------------------------------------------#
# 1. 智能 Swap 判断与配置 (针对小内存优化)
#-----------------------------------------------------------------#
MEM_TOTAL=$(free -m | grep Mem | awk '{print $2}')
SWAP_TOTAL=$(free -m | grep Swap | awk '{print $2}')

if [ "$SWAP_TOTAL" -eq 0 ]; then
    echo -e "${YELLOW}检测到系统未配置 Swap，正在进行智能分配...${PLAIN}"
    # 512MB 左右的机器分配 2G Swap 是最稳妥的
    if [ "$MEM_TOTAL" -le 600 ]; then
        SWAP_SIZE="2G"
    elif [ "$MEM_TOTAL" -le 1024 ]; then
        SWAP_SIZE="1G"
    else
        SWAP_SIZE="512M"
    fi
    fallocate -l $SWAP_SIZE /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' | tee -a /etc/fstab
fi

#-----------------------------------------------------------------#
# 2. 交互式参数询问
#-----------------------------------------------------------------#
read -p "请输入您的域名 (默认: ema.ink): " DOMAIN
[ -z "${DOMAIN}" ] && DOMAIN="ema.ink"

read -p "请输入您的邮箱 (用于 SSL 通知): " EMAIL
[ -z "${EMAIL}" ] && EMAIL="admin@${DOMAIN}"

#-----------------------------------------------------------------#
# 3. 安装依赖与 Docker
#-----------------------------------------------------------------#
apt update && apt install -y curl vim ufw nginx certbot python3-certbot-nginx
if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com -o get-docker.sh && sh get-docker.sh
    systemctl enable --now docker
fi

#-----------------------------------------------------------------#
# 4. 部署 n8n 容器 (修复权限与端口暴露)
#-----------------------------------------------------------------#
mkdir -p ~/n8n/n8n_data
# 核心：预设权限防止 EACCES 报错
chown -R 1000:1000 ~/n8n/n8n_data

cat > ~/n8n/docker-compose.yml <<EOF
services:
  n8n:
    image: blowsnow/n8n-chinese:latest
    container_name: n8n
    restart: always
    ports:
      - "127.0.0.1:5678:5678" # 仅允许本地访问，更安全
    environment:
      - N8N_HOST=${DOMAIN}
      - N8N_PORT=5678
      - N8N_PROTOCOL=https
      - WEBHOOK_URL=https://${DOMAIN}/
      - GENERIC_TIMEZONE=Asia/Shanghai
      - N8N_DEFAULT_LOCALE=zh-CN
      - N8N_PAYLOAD_SIZE_MAX=100
      - N8N_BINARY_DATA_MODE=filesystem # 强制图片存硬盘，省内存
      - EXECUTIONS_DATA_PRUNE=true
      - EXECUTIONS_DATA_MAX_AGE=72
    volumes:
      - ./n8n_data:/home/node/.n8n
EOF

cd ~/n8n && docker compose up -d

#-----------------------------------------------------------------#
# 5. 配置 Nginx 与 SSL (修复大文件上传)
#-----------------------------------------------------------------#
cat > /etc/nginx/sites-available/n8n <<EOF
server {
    listen 80;
    server_name ${DOMAIN};
    client_max_body_size 100M; # 解决大图上传报错
    location / {
        proxy_pass http://127.0.0.1:5678;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_buffering off;
    }
}
EOF

ln -sf /etc/nginx/sites-available/n8n /etc/nginx/sites-enabled/
nginx -t && systemctl reload nginx
certbot --nginx -d ${DOMAIN} --non-interactive --agree-tos --email ${EMAIL} --redirect

#-----------------------------------------------------------------#
# 6. 自动更新 (修复 API 版本冲突)
#-----------------------------------------------------------------#
docker rm -f watchtower > /dev/null 2>&1
docker run -d \
  --name watchtower \
  -e DOCKER_API_VERSION=1.44 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  containrrr/watchtower \
  --cleanup \
  --schedule "0 0 0 * * *" \
  n8n

echo -e "\n${GREEN}部署完成！请访问 https://${DOMAIN}${PLAIN}"
