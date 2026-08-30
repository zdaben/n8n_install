#!/bin/bash
#=================================================================#
#  System Required: Debian 12+ / Ubuntu 22+                       #
#  Description: n8n CLI Management Tool (V2.3 Production Final)   #
#  Author: zdaben (https://github.com/zdaben/n8n_install)         #
#=================================================================#

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

N8N_DIR="/root/n8n"
BACKUP_DIR="${N8N_DIR}/backup"
DOCKER_COMPOSE_CMD=""
I18N_REPO="zdaben/n8n-chinese"

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}错误：必须使用 root 用户运行。${PLAIN}"
        exit 1
    fi
}

init_docker_compose() {
    if docker compose version &> /dev/null; then
        DOCKER_COMPOSE_CMD="docker compose"
    elif command -v docker-compose &> /dev/null; then
        DOCKER_COMPOSE_CMD="docker-compose"
    else
        echo -e "${RED}错误：Docker Compose 未安装或无法运行。${PLAIN}"
        exit 1
    fi
}

# --- 1. 严格对齐版本契约 (NPM latest -> GitHub Non-Prerelease) ---
get_official_latest_version() {
    local VER=""

    # 权威源 1: NPM 官方 registry (权威、CDN 加速、无速率限制)
    VER=$(curl -fsSL --connect-timeout 5 --max-time 10 "https://registry.npmjs.org/n8n/latest" 2>/dev/null \
        | jq -r '.version // empty' 2>/dev/null || true)

    # 权威源 2: GitHub Releases 过滤正式版本
    if [ -z "$VER" ]; then
        VER=$(curl -fsSL --connect-timeout 5 --max-time 10 -H "Accept: application/vnd.github.v3+json" "https://api.github.com/repos/n8n-io/n8n/releases" 2>/dev/null \
            | jq -r '[.[] | select(.prerelease == false and (.tag_name | contains("alpha") or contains("beta") | not))] | .[0].tag_name' 2>/dev/null \
            | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' \
            | head -n1 || true)
    fi

    if [ -z "$VER" ]; then
        echo -e "${RED}错误：无法连接上游官方源确认 Stable 版本，操作已终止。${PLAIN}" >&2
        return 1
    fi
    echo "$VER"
}

download_i18n_patch() {
    local TVERSION="$1"
    echo -e "${GREEN}==> 正在检索 v${TVERSION} 汉化补丁包...${PLAIN}"
    local URL="https://github.com/${I18N_REPO}/releases/download/release%2F${TVERSION}/editor-ui.tar.gz"

    rm -f /tmp/editor-ui.tar.gz
    if curl -fsSL --retry 2 -o /tmp/editor-ui.tar.gz "$URL"; then
        echo -e "${CYAN}命中并成功下载 v${TVERSION} 汉化补丁。${PLAIN}"
        return 0
    else
        echo -e "${YELLOW}未检索到 v${TVERSION} 对应的汉化补丁。${PLAIN}"
        return 1
    fi
}

set_i18n_mount() {
    local ENABLE="$1"
    local COMPOSE_FILE="${N8N_DIR}/docker-compose.yml"
    [ ! -f "$COMPOSE_FILE" ] && return 0

    sed -i '/n8n_ui\/dist:/d' "$COMPOSE_FILE"

    if [ "$ENABLE" = "true" ]; then
        sed -i '/- .\/n8n_files:\/files/a\      - ./n8n_ui/dist:/usr/local/lib/node_modules/n8n/node_modules/n8n-editor-ui/dist' "$COMPOSE_FILE"
    fi
}

wait_for_n8n() {
    local PORT="$1"
    echo -e "${GREEN}==> 正在等待 n8n 服务健康就绪...${PLAIN}"
    for i in $(seq 1 30); do
        if curl -fsS "http://127.0.0.1:${PORT}/healthz" >/dev/null 2>&1; then
            echo -e "${GREEN}n8n 健康检查通过！${PLAIN}"
            return 0
        fi
        sleep 2
    done
    return 1
}

cmd_show_panel() {
    if [ ! -f "${N8N_DIR}/docker-compose.yml" ]; then
        echo -e "${YELLOW}n8n 尚未配置，请执行 n8n install 开始安装。${PLAIN}"
        exit 0
    fi

    local DOMAIN=$(grep -E 'N8N_HOST=' "${N8N_DIR}/docker-compose.yml" | cut -d'=' -f2 | tr -d '"\r ' || echo "未知")
    local PORT=$(grep -oE '127\.0\.0\.1:[0-9]+' "${N8N_DIR}/docker-compose.yml" | cut -d':' -f2 | head -n 1 || echo "5678")

    echo -e "\n${GREEN}===========================================================${PLAIN}"
    echo -e "${GREEN}n8n 管理面板 (V2.3 Production)${PLAIN}"
    echo -e "-----------------------------------------------------------"
    echo -e "访问地址: ${YELLOW}https://${DOMAIN}${PLAIN}"
    echo -e "管理账号: ${CYAN}admin${PLAIN}"
    echo -e "管理密码: ${CYAN}********${PLAIN} ${YELLOW}(运行 'n8n secrets' 查看明文)${PLAIN}"
    echo -e "加密密钥: ${CYAN}********${PLAIN} ${YELLOW}(运行 'n8n secrets' 查看明文)${PLAIN}"
    echo -e "内部端口: ${CYAN}${PORT}${PLAIN}"
    echo -e "-----------------------------------------------------------"
    echo -e "常用指令:"
    echo -e "  ${YELLOW}n8n status${PLAIN}    - 查看服务状态与资源占用"
    echo -e "  ${YELLOW}n8n update${PLAIN}    - 升级官方引擎 (支持自动回滚)"
    echo -e "  ${YELLOW}n8n secrets${PLAIN}   - 查看明文账号、密码与加密密钥"
    echo -e "  ${YELLOW}n8n restart${PLAIN}   - 重启容器服务"
    echo -e "  ${YELLOW}n8n backup${PLAIN}    - 立即全量备份 (含数据与 UI)"
    echo -e "  ${YELLOW}n8n recover${PLAIN}   - 从历史归档中恢复数据"
    echo -e "  ${RED}n8n uninstall${PLAIN} - 彻底卸载并清理数据"
    echo -e "===========================================================${PLAIN}"
}

cmd_secrets() {
    check_root
    if [ ! -f "${N8N_DIR}/docker-compose.yml" ]; then
        echo -e "${RED}错误：配置文件不存在。${PLAIN}"
        exit 1
    fi
    local PASS=$(grep -E 'N8N_BASIC_AUTH_PASSWORD=' "${N8N_DIR}/docker-compose.yml" | cut -d'=' -f2 | tr -d '"\r ')
    local KEY=$(grep -E 'N8N_ENCRYPTION_KEY=' "${N8N_DIR}/docker-compose.yml" | cut -d'=' -f2 | tr -d '"\r ')
    
    echo -e "\n${YELLOW}=== [敏感信息] n8n 核心凭据 ===${PLAIN}"
    echo -e "管理账号: ${CYAN}admin${PLAIN}"
    echo -e "管理密码: ${CYAN}${PASS}${PLAIN}"
    echo -e "加密密钥: ${CYAN}${KEY}${PLAIN}"
    echo -e "================================\n"
}

cmd_install() {
    check_root
    echo -e "${GREEN}==> 正在准备系统环境与必要依赖...${PLAIN}"
    apt update && apt install -y curl vim nginx certbot python3-certbot-nginx jq tar cron dnsutils iproute2 util-linux

    if ! command -v docker &> /dev/null; then
        curl -fsSL https://get.docker.com | bash
        apt install -y docker-compose-plugin
        systemctl enable --now docker
    fi
    init_docker_compose

    local MEM_TOTAL=$(free -m | awk '/Mem/{print $2}')
    if [ "$MEM_TOTAL" -le 2048 ] && [ ! -f /swapfile ]; then
        echo -e "${GREEN}==> 为小内存主机配置 2GB 虚拟内存...${PLAIN}"
        fallocate -l 2048M /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048
        chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
        echo '/swapfile none swap sw 0 0' | tee -a /etc/fstab || true
    fi

    mkdir -p "${N8N_DIR}/n8n_data" "${N8N_DIR}/n8n_files" "${N8N_DIR}/n8n_ui" "${BACKUP_DIR}"
    chown -R 1000:1000 "${N8N_DIR}/n8n_data" "${N8N_DIR}/n8n_files" "${N8N_DIR}/n8n_ui"

    local OLD_DOMAIN="" OLD_PORT="" OLD_KEY="" OLD_PASS=""
    if [ -f "${N8N_DIR}/docker-compose.yml" ]; then
        OLD_DOMAIN=$(grep -E 'N8N_HOST=' "${N8N_DIR}/docker-compose.yml" | cut -d'=' -f2 | tr -d '"\r ' || true)
        OLD_KEY=$(grep -E 'N8N_ENCRYPTION_KEY=' "${N8N_DIR}/docker-compose.yml" | cut -d'=' -f2 | tr -d '"\r ' || true)
        OLD_PASS=$(grep -E 'N8N_BASIC_AUTH_PASSWORD=' "${N8N_DIR}/docker-compose.yml" | cut -d'=' -f2 | tr -d '"\r ' || true)
        OLD_PORT=$(grep -oE '127\.0\.0\.1:[0-9]+' "${N8N_DIR}/docker-compose.yml" | cut -d':' -f2 | head -n 1 || true)
    fi

    read -p "请输入绑定域名 (默认: ${OLD_DOMAIN:-n8n.example.com}): " INPUT_DOMAIN
    DOMAIN=${INPUT_DOMAIN:-${OLD_DOMAIN:-"n8n.example.com"}}
    read -p "请输入管理员邮箱 (用于 SSL 证书申请): " INPUT_EMAIL
    EMAIL=${INPUT_EMAIL:-"admin@${DOMAIN}"}
    read -p "请输入宿主机映射端口 [默认: ${OLD_PORT:-5678}]: " INPUT_PORT
    N8N_PORT=${INPUT_PORT:-${OLD_PORT:-5678}}

    RANDOM_KEY=${OLD_KEY:-$(tr -dc 'a-z0-9' </dev/urandom | head -c 32)}
    BASIC_AUTH_PASS=${OLD_PASS:-$(tr -dc 'a-z0-9' </dev/urandom | head -c 12)}

    local TARGET_VERSION
    TARGET_VERSION=$(get_official_latest_version)
    echo -e "准备安装 n8n 官方引擎版本: ${CYAN}v${TARGET_VERSION}${PLAIN}"

    cat > "${N8N_DIR}/docker-compose.yml" <<EOF
services:
  n8n:
    image: n8nio/n8n:${TARGET_VERSION}
    container_name: n8n
    restart: unless-stopped
    ports: ["127.0.0.1:${N8N_PORT}:5678"]
    logging:
      driver: "json-file"
      options: { max-size: "50m", max-file: "5" }
    environment:
      - TZ=Asia/Shanghai
      - NODE_OPTIONS=--max-old-space-size=512
      - N8N_HOST=${DOMAIN}
      - N8N_PORT=5678
      - N8N_PROTOCOL=https
      - N8N_WEBHOOK_URL=https://${DOMAIN}/
      - N8N_EDITOR_BASE_URL=https://${DOMAIN}/
      - GENERIC_TIMEZONE=Asia/Shanghai
      - N8N_DEFAULT_LOCALE=zh-CN
      - N8N_ENCRYPTION_KEY=${RANDOM_KEY}
      - N8N_METRICS=true
      - EXECUTIONS_DATA_PRUNE=true
      - EXECUTIONS_DATA_MAX_AGE=72
      - EXECUTIONS_DATA_PRUNE_MAX_COUNT=20000
      - N8N_BASIC_AUTH_ACTIVE=true
      - N8N_BASIC_AUTH_USER=admin
      - N8N_BASIC_AUTH_PASSWORD=${BASIC_AUTH_PASS}
    volumes:
      - ./n8n_data:/home/node/.n8n
      - ./n8n_files:/files
EOF

    if download_i18n_patch "$TARGET_VERSION"; then
        rm -rf "${N8N_DIR}/n8n_ui/dist"
        tar -xzf /tmp/editor-ui.tar.gz -C "${N8N_DIR}/n8n_ui"
        chown -R 1000:1000 "${N8N_DIR}/n8n_ui"
        rm -f /tmp/editor-ui.tar.gz
        set_i18n_mount true
    else
        echo -e "${YELLOW}降级提示：当前版本未命中汉化包，系统将安全使用官方原生 UI。${PLAIN}"
        set_i18n_mount false
    fi

    cd "${N8N_DIR}" && $DOCKER_COMPOSE_CMD pull && $DOCKER_COMPOSE_CMD up -d

    if ! wait_for_n8n "$N8N_PORT"; then
        echo -e "${RED}部署失败：容器未能通过健康检查，请检查 docker logs n8n。${PLAIN}"
        exit 1
    fi

    rm -f /etc/nginx/sites-enabled/default || true
    cat > /etc/nginx/sites-available/n8n <<EOF
server {
    listen 80;
    server_name ${DOMAIN};
    server_tokens off;
    client_max_body_size 100M;

    location / {
        proxy_pass http://127.0.0.1:${N8N_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 3600;
        proxy_send_timeout 3600;
        proxy_buffering off;
    }
}
EOF
    ln -sf /etc/nginx/sites-available/n8n /etc/nginx/sites-enabled/
    nginx -t && systemctl reload nginx

    echo -e "${GREEN}==> 配置 SSL 证书...${PLAIN}"
    certbot --nginx -d "${DOMAIN}" --non-interactive --agree-tos --email "${EMAIL}" --redirect --keep-until-expiring || echo -e "${YELLOW}提示：SSL 证书自动申请未完成，可在域名正确解析后手动执行 certbot --nginx。${PLAIN}"

    (crontab -l 2>/dev/null | grep -v "n8n backup"; echo "0 3 * * * /usr/local/bin/n8n backup > /dev/null 2>&1") | crontab - || true

    cmd_show_panel
}

# --- 核心升级函数：包含完整的自动回滚机制 ---
cmd_update() {
    check_root; init_docker_compose
    local CURRENT_VERSION
    CURRENT_VERSION=$(grep -oE 'n8nio/n8n:[a-zA-Z0-9.-]+' "${N8N_DIR}/docker-compose.yml" | cut -d':' -f2 || echo "未知")
    
    local LATEST_OFFICIAL
    LATEST_OFFICIAL=$(get_official_latest_version)

    local PORT=$(grep -oE '127\.0\.0\.1:[0-9]+' "${N8N_DIR}/docker-compose.yml" | cut -d':' -f2 | head -n 1 || echo "5678")

    echo -e "当前本地运行版本: ${CYAN}v${CURRENT_VERSION}${PLAIN}"
    echo -e "官方最新 Stable 版本: ${YELLOW}v${LATEST_OFFICIAL}${PLAIN}"

    if [ "$CURRENT_VERSION" == "$LATEST_OFFICIAL" ]; then
        echo -e "\n${GREEN}当前系统已经是官方最新稳定版本。${PLAIN}"
        read -p "是否强制重新拉取并部署？(y/n) [默认: n]: " FORCE_UPDATE
        [[ ! "$FORCE_UPDATE" =~ ^[Yy]$ ]] && exit 0
    fi

    read -p "确认升级至 v${LATEST_OFFICIAL}？(y/n) [默认: y]: " CONFIRM
    [[ "$CONFIRM" =~ ^[Nn]$ ]] && exit 0

    echo -e "${GREEN}==> 正在创建升级前环境快照 (用于故障自动回滚)...${PLAIN}"
    cp "${N8N_DIR}/docker-compose.yml" "${N8N_DIR}/docker-compose.yml.bak"
    rm -rf /tmp/n8n_ui_bak
    [ -d "${N8N_DIR}/n8n_ui" ] && cp -r "${N8N_DIR}/n8n_ui" /tmp/n8n_ui_bak

    # 尝试下载新补丁
    if download_i18n_patch "$LATEST_OFFICIAL"; then
        rm -rf "${N8N_DIR}/n8n_ui/dist"
        tar -xzf /tmp/editor-ui.tar.gz -C "${N8N_DIR}/n8n_ui"
        chown -R 1000:1000 "${N8N_DIR}/n8n_ui"
        rm -f /tmp/editor-ui.tar.gz
        set_i18n_mount true
    else
        echo -e "${YELLOW}升级提示：新版本未检测到匹配汉化包，自动移除旧 UI 挂载并使用官方原生界面。${PLAIN}"
        rm -rf "${N8N_DIR}/n8n_ui/dist"
        set_i18n_mount false
    fi

    sed -i "s|image: n8nio/n8n:.*|image: n8nio/n8n:${LATEST_OFFICIAL}|g" "${N8N_DIR}/docker-compose.yml"
    cd "${N8N_DIR}" && $DOCKER_COMPOSE_CMD pull && $DOCKER_COMPOSE_CMD up -d

    # 探针验证：如果失败执行自动回滚
    if ! wait_for_n8n "$PORT"; then
        echo -e "\n${RED}===========================================================${PLAIN}"
        echo -e "${RED}⚠️  检测到 v${LATEST_OFFICIAL} 启动异常！触发原子级自动回滚机制...${PLAIN}"
        echo -e "${RED}===========================================================${PLAIN}"

        # 1. 恢复 Compose 与 UI 快照
        cp "${N8N_DIR}/docker-compose.yml.bak" "${N8N_DIR}/docker-compose.yml"
        rm -rf "${N8N_DIR}/n8n_ui"
        [ -d /tmp/n8n_ui_bak ] && cp -r /tmp/n8n_ui_bak "${N8N_DIR}/n8n_ui"

        # 2. 拉起原版本
        $DOCKER_COMPOSE_CMD up -d

        # 3. 再次校验回滚状态
        if wait_for_n8n "$PORT"; then
            echo -e "${GREEN}✅ 已成功回滚至原版本 v${CURRENT_VERSION}，服务运行正常。${PLAIN}"
        else
            echo -e "${RED}❌ 回滚后服务依然异常，请立即执行 'docker logs n8n' 查看数据库或配置错误！${PLAIN}"
        fi

        rm -f "${N8N_DIR}/docker-compose.yml.bak" /tmp/n8n_ui_bak
        exit 1
    fi

    # 清理临时备份
    rm -f "${N8N_DIR}/docker-compose.yml.bak"
    rm -rf /tmp/n8n_ui_bak
    docker image prune -f
    echo -e "${GREEN}升级完成且健康检查通过！当前运行版本: ${CYAN}v${LATEST_OFFICIAL}${PLAIN}"
}

cmd_backup() {
    mkdir -p "${BACKUP_DIR}"
    local FILE="${BACKUP_DIR}/n8n_$(date +%Y%m%d_%H%M%S).tar.gz"
    cd "${N8N_DIR}"
    # 将 UI 与配置一并纳入原子化灾备
    nice -n 19 ionice -c2 -n7 tar czf "${FILE}" n8n_data n8n_files n8n_ui docker-compose.yml
    find "${BACKUP_DIR}" -name "n8n_*.tar.gz" -mtime +7 -delete
    echo -e "${GREEN}备份完成: ${CYAN}${FILE}${PLAIN} (包含数据、配置与前端 UI，保留 7 天)"
}

cmd_recover() {
    init_docker_compose
    if [ ! -d "${BACKUP_DIR}" ] || ! ls "${BACKUP_DIR}"/n8n_*.tar.gz 1> /dev/null 2>&1; then
        echo -e "${RED}未找到任何备份归档文件！${PLAIN}"
        exit 1
    fi

    ls -lh "${BACKUP_DIR}"/n8n_*.tar.gz | awk '{print NR". "$9}' | sed "s|${BACKUP_DIR}/||"
    read -p "请选择要恢复的备份编号 (输入 0 取消): " IDX
    [ "$IDX" -eq 0 ] && exit 0

    local FILE=$(ls "${BACKUP_DIR}"/n8n_*.tar.gz | sed -n "${IDX}p")
    cd "${N8N_DIR}" && $DOCKER_COMPOSE_CMD down
    rm -rf n8n_data n8n_files n8n_ui docker-compose.yml
    tar xzf "${FILE}" -C "${N8N_DIR}"
    chown -R 1000:1000 n8n_data n8n_files n8n_ui 2>/dev/null || true
    $DOCKER_COMPOSE_CMD up -d
    echo -e "${GREEN}数据与 UI 恢复完成！${PLAIN}"
}

cmd_uninstall() {
    check_root
    echo -e "${RED}警告：此操作将彻底删除 n8n 容器、数据、所有历史备份及 Nginx 反代配置！${PLAIN}"
    read -p "确认卸载请输入 'yes': " CONFIRM
    if [ "$CONFIRM" == "yes" ]; then
        init_docker_compose
        if [ -d "${N8N_DIR}" ]; then
            cd "${N8N_DIR}" && $DOCKER_COMPOSE_CMD down -v || true
        fi
        rm -rf "${N8N_DIR}" /etc/nginx/sites-available/n8n /etc/nginx/sites-enabled/n8n /usr/local/bin/n8n
        systemctl reload nginx || true
        crontab -l | grep -v "n8n backup" | crontab - || true
        echo -e "${GREEN}n8n 卸载并清理完成。${PLAIN}"
    else
        echo "已取消卸载。"
    fi
}

cmd_status() {
    init_docker_compose
    local VERSION=$(grep -oE 'n8nio/n8n:[a-zA-Z0-9.-]+' "${N8N_DIR}/docker-compose.yml" | cut -d':' -f2 || echo "未知")
    echo -e "\n${GREEN}▶ n8n 当前运行版本: ${CYAN}v${VERSION}${PLAIN}"
    echo -e "-----------------------------------------------------------"
    docker ps -f name=n8n
    echo -e "\n${GREEN}▶ 资源占用快照:${PLAIN}"
    docker stats --no-stream n8n
}

cmd_top() {
    init_docker_compose
    echo -e "${YELLOW}提示: 正在进入实时监控模式，按 Ctrl+C 退出。${PLAIN}"
    docker stats n8n
}

case "$1" in
    install)   cmd_install ;;
    update)    cmd_update ;;
    secrets)   cmd_secrets ;;
    status)    cmd_status ;;
    top)       cmd_top ;;
    restart)   init_docker_compose && cd "${N8N_DIR}" && $DOCKER_COMPOSE_CMD restart ;;
    backup)    cmd_backup ;;
    recover)   cmd_recover ;;
    uninstall) cmd_uninstall ;;
    *) cmd_show_panel ;;
esac
