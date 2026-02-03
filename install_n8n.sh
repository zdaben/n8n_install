#!/bin/bash
#=================================================================#
#  System Required: Debian 12+                                    #
#  Description: One-click deployment for n8n (Chinese Version)    #
#  Author: Gemini (Based on your deployment journey)              #
#=================================================================#

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# 权限检查
[[ $EUID -ne 0 ]] && echo -e "${RED}错误：${PLAIN}必须使用 root 用户运行此脚本！\n" && exit 1

echo -e "${GREEN}正在启动 n8n 一键部署脚本...${PLAIN}"

#-----------------------------------------------------------------#
# 1. 智能 Swap 判断与配置
#-----------------------------------------------------------------#
echo -e "${YELLOW}正在检测系统内存与 Swap 状态...${PLAIN}"
MEM_TOTAL=$(free -m | grep Mem | awk '{print $2}')
SWAP_TOTAL=$(free -m | grep Swap | awk '{print $2}')

if [ "$SWAP_TOTAL" -eq 0 ]; then
    echo -e "${YELLOW}检测到系统未配置 Swap，正在进行智能分配...${PLAIN}"
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
    echo -e "${GREEN}Swap 配置完成：已分配 $SWAP_SIZE${PLAIN}"
else
    echo -e "${GREEN}系统已存在 Swap ($SWAP_TOTAL MB)，跳过配置。${PLAIN}"
fi

#-----------------------------------------------------------------#
# 2. 交互式参数询问
#-----------------------------------------------------------------#
echo -e "${YELLOW}请配置部署参数（回车使用默认值）：${PLAIN}"

# 域名配置
read -p "请输入您的域名 (默认: ema.ink): " DOMAIN
[ -z "${DOMAIN}" ] && DOMAIN="ema.ink"

# 邮箱配置（用于 SSL）
read -p "请输入您的邮箱 (用于 SSL 证书通知): " EMAIL
[ -z "${EMAIL}" ] && EMAIL="admin@${DOMAIN}"

# 时区配置
read -p "请输入系统时区 (默认: Asia/Shanghai): " TIMEZONE
[ -z "${TIMEZONE}" ] && TIMEZONE="Asia/Shanghai"

echo -e "\n${GREEN}配置确认：${PLAIN}"
echo -e "域名: ${DOMAIN}"
echo -e "邮箱: ${EMAIL}"
echo -e "时区: ${TIMEZONE}"
echo -e "-----------------------------------------------------------"

#-----------------------------------------------------------------#
# 3. 安装依赖与 Docker
#-----------------------------------------------------------------#
echo -e "${YELLOW}正在安装必要依赖与 Docker...${PLAIN}"
apt update && apt install -y curl vim git ufw nginx certbot python3-certbot-nginx

if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh
    systemctl enable --now docker
fi

#-----------------------------------------------------------------#
# 4. 部署 n8n 容器
#-----------------------------------------------------------------#
echo -e "${YELLOW}正在配置 n8n 容器环境...${PLAIN}"
mkdir -p ~/n8n/n8n_data
chown -R 1000:1000 ~/n8n/n8n_data

cat > ~/n8n/docker-compose.yml <<EOF
services:
  n8n:
    image: blowsnow/n8n-chinese:latest
    container_name: n8n
    restart: always
    ports:
      - "5678:5678"
    environment:
      - N8N_HOST=${DOMAIN}
      - N8N_PORT=5678
      - N8N_PROTOCOL=https
      - NODE_ENV=production
      - WEBHOOK_URL=https://${DOMAIN}/
      - GENERIC_TIMEZONE=${TIMEZONE}
      - N8N_DEFAULT_LOCALE=zh-CN
      - N8N_PAYLOAD_SIZE_MAX=100
      - N8N_BINARY_DATA_MODE=filesystem
      - N8N_BINARY_DATA_STORAGE_PATH=/home/node/.n8n/binaryData
      - EXECUTIONS_DATA_PRUNE=true
      - EXECUTIONS_DATA_MAX_AGE=72
    volumes:
      - ./n8n_data:/home/node/.n8n
EOF

cd ~/n8n && docker compose up -d

#-----------------------------------------------------------------#
# 5. 配置 Nginx 反向代理
#-----------------------------------------------------------------#
echo -e "${YELLOW}正在配置 Nginx 反向代理...${PLAIN}"
cat > /etc/nginx/sites-available/n8n <<EOF
server {
    listen 80;
    server_name ${DOMAIN};
    client_max_body_size 100M;
    location / {
        proxy_pass http://127.0.0.1:5678;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_buffering off;
    }
}
EOF

ln -sf /etc/nginx/sites-available/n8n /etc/nginx/sites-enabled/
nginx -t && systemctl reload nginx

#-----------------------------------------------------------------#
# 6. 获取 SSL 证书与 Watchtower
#-----------------------------------------------------------------#
echo -e "${YELLOW}正在申请 SSL 证书并部署 Watchtower...${PLAIN}"
certbot --nginx -d ${DOMAIN} --non-interactive --agree-tos --email ${EMAIL} --redirect

docker run -d \
  --name watchtower \
  -v /var/run/docker.sock:/var/run/docker.sock \
  containrrr/watchtower \
  --cleanup \
  --schedule "0 0 0 * * *" \
  n8n

#-----------------------------------------------------------------#
# 7. 部署完成
#-----------------------------------------------------------------#
echo -e "\n${GREEN}===========================================================${PLAIN}"
echo -e "${GREEN}恭喜！n8n 已成功部署并完成汉化。${PLAIN}"
echo -e "访问地址: ${YELLOW}https://${DOMAIN}${PLAIN}"
echo -e "数据目录: ~/n8n/n8n_data"
echo -e "自动更新: 每天凌晨 00:00 (Watchtower)"
echo -e "Swap 状态: 已通过智能判断优化"
echo -e "${GREEN}===========================================================${PLAIN}"
