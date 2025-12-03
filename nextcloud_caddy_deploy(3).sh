#!/bin/bash
# 优化版Nextcloud一键部署脚本（含Collabora协作编辑）- 使用Caddy作为反向代理
# 注意：此脚本仅适用于Linux系统

set -euo pipefail
# set -x

# 核心配置（优先使用环境变量指定路径）
# 优先级：命令行参数 > 环境变量 > 默认路径
PROJECT_ROOT="${1:-${NC_PROJECT_ROOT:-$HOME/nextcloud}}"
# 转换为绝对路径（避免相对路径问题）
PROJECT_ROOT=$(realpath "$PROJECT_ROOT")
CONFIG_DIR="$PROJECT_ROOT/configs"
ENV_FILE="$CONFIG_DIR/.env"

# 目录定义
BACKUP_DIR="$HOME/nextcloud_backups/"

# 网络配置
HTTPS_PORT=${HTTPS_PORT:-18443}
SERVER_IP=$(hostname -I | cut -d' ' -f1)
[ -z "$SERVER_IP" ] && SERVER_IP="127.0.0.1"

# 颜色输出配置
GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[1;33m"
NC="\033[0m"
info() { echo -e "${GREEN}? $1${NC}"; }
error() { echo -e "${RED}? $1${NC}"; exit 1; }
warning() { echo -e "${YELLOW}? $1${NC}"; }

# 容器镜像配置
NEXTCLOUD_IMAGE="nextcloud:production-fpm-alpine"
MARIADB_IMAGE="mariadb:11.4"
COLLABORA_IMAGE="collabora/code:latest"
CADDY_IMAGE="caddy:2.10.0-alpine"
REDIS_IMAGE="redis:alpine"

# Docker Compose命令兼容处理
if docker compose version &>/dev/null; then
  DOCKER_COMPOSE_CMD="docker compose"
elif docker-compose version &>/dev/null; then
  DOCKER_COMPOSE_CMD="docker-compose"
else
  error "未找到docker compose或docker-compose，请先安装"
fi

# 检查端口占用
check_ports() {
  local port="$HTTPS_PORT"
  if (command -v ss >/dev/null && ss -tuln | grep -q ":$port\b") ||
     (command -v netstat >/dev/null && netstat -tuln | grep -q ":$port\b"); then
    error "端口 $port 已被占用，请释放后重试"
  fi
}

# 依赖检查
check_deps() {
  info "检查系统依赖..."
  local deps=("docker" "openssl" "tar" "find")
  for dep in "${deps[@]}"; do
    if ! command -v "$dep" &>/dev/null; then
      error "缺少必要依赖: $dep"
    fi
  done
}

# 目录初始化（简化版，只需创建配置目录）
init_dirs() {
  info "初始化目录结构..."
  mkdir -p "$CONFIG_DIR"
  chmod 755 "$PROJECT_ROOT" "$CONFIG_DIR"
}

# 生成环境变量
gen_env() {
  [ -f "$ENV_FILE" ] && { info "加载现有环境配置"; source "$ENV_FILE"; return; }

  info "生成安全配置信息..."
  ADMIN_USER="${ADMIN_USER:-admin}"
  ADMIN_PASS="${ADMIN_PASS:-$(openssl rand -hex 12)}"
  MYSQL_PASSWORD=$(openssl rand -hex 12)
  MYSQL_ROOT_PASSWORD=$(openssl rand -hex 16)
  REDIS_PASSWORD=$(openssl rand -hex 16)
  COLLABORA_PASSWORD=$(openssl rand -hex 12)

  cat > "$ENV_FILE" <<EOF
# 管理员账户
ADMIN_USER=$ADMIN_USER
ADMIN_PASS=$ADMIN_PASS

# 数据库密码
MYSQL_PASSWORD=$MYSQL_PASSWORD
MYSQL_ROOT_PASSWORD=$MYSQL_ROOT_PASSWORD

# 缓存服务密码
REDIS_PASSWORD=$REDIS_PASSWORD

# 在线编辑服务密码
COLLABORA_PASSWORD=$COLLABORA_PASSWORD

# 网络配置
SERVER_IP=$SERVER_IP
HTTPS_PORT=$HTTPS_PORT
EOF
  chmod 600 "$ENV_FILE"

  cat <<EOF
重要提示:
  - 请妥善保管管理员密码，首次登录后建议立即修改
  - 由于使用自签名证书，访问时请点击"高级"->"继续访问"
EOF
  info "管理员账号: $ADMIN_USER"
  info "管理员密码: $ADMIN_PASS"
  info "访问地址: https://$SERVER_IP:$HTTPS_PORT"
}

# 生成核心配置文件
gen_configs() {
  info "生成服务配置文件..."
  [ ! -f "$ENV_FILE" ] && error "环境配置文件不存在，请先运行初始化"
  source "$ENV_FILE"

  cat > "$CONFIG_DIR/docker-compose.yml" <<EOF
networks:
  nextcloud_network:
    driver: bridge
    ipam:
      config:
        - subnet: 172.19.0.0/16

volumes:
  nextcloud_data:
    name: nextcloud_data
  db_data:
    name: nextcloud_db_data
  redis_data:
    name: nextcloud_redis_data
  caddy_data:
    name: nextcloud_caddy_data
  caddy_config:
    name: nextcloud_caddy_config

x-logging: &default-logging
  driver: "json-file"
  options:
    max-size: "10m"
    max-file: "5"

services:
  mariadb:
    image: $MARIADB_IMAGE
    restart: always
    volumes:
      - db_data:/var/lib/mysql
    environment:
      - MYSQL_ROOT_PASSWORD=$MYSQL_ROOT_PASSWORD
      - MYSQL_DATABASE=nextcloud
      - MYSQL_USER=nextcloud
      - MYSQL_PASSWORD=$MYSQL_PASSWORD
    networks: [nextcloud_network]
    command: --transaction-isolation=READ-COMMITTED --binlog-format=ROW
    healthcheck:
      test: ["CMD", "mariadb-admin", "ping", "-h", "localhost", "-u", "root", "-p$MYSQL_ROOT_PASSWORD"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 60s
    logging: *default-logging

  redis:
    image: $REDIS_IMAGE
    restart: always
    command: redis-server --requirepass $REDIS_PASSWORD --save 60 1
    networks: [nextcloud_network]
    volumes:
      - redis_data:/data
    healthcheck:
      test: ["CMD", "redis-cli", "-u", "redis://default:$REDIS_PASSWORD@localhost:6379", "PING"]
      interval: 5s
      timeout: 3s
      retries: 3
      start_period: 10s
    logging: *default-logging

  nextcloud:
    image: $NEXTCLOUD_IMAGE
    restart: always
    volumes:
      - nextcloud_data:/var/www/html
    environment:
      - MYSQL_DATABASE=nextcloud
      - MYSQL_USER=nextcloud
      - MYSQL_PASSWORD=$MYSQL_PASSWORD
      - MYSQL_HOST=mariadb
      - NEXTCLOUD_ADMIN_USER=$ADMIN_USER
      - NEXTCLOUD_ADMIN_PASSWORD=$ADMIN_PASS
      - REDIS_HOST=redis
      - REDIS_HOST_PASSWORD=$REDIS_PASSWORD
      - NEXTCLOUD_TRUSTED_DOMAINS=$SERVER_IP:$HTTPS_PORT
      - NEXTCLOUD_TRUSTED_PROXIES=172.19.0.0/16
      - OVERWRITEHOST=$SERVER_IP:$HTTPS_PORT
      - OVERWRITEPROTOCOL=https
      - OVERWRITECLIURL=https://$SERVER_IP:$HTTPS_PORT
      - PHP_MEMORY_LIMIT=1024M
      - PHP_UPLOAD_LIMIT=10G
      - PHP_MAX_EXECUTION_TIME=3600
      - PHP_MAX_INPUT_VARS=10000
      - TZ=Asia/Shanghai
    networks: [nextcloud_network]
    healthcheck:
      test: ["CMD-SHELL", "php /var/www/html/occ status | grep -q 'installed: true' || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 180s
    depends_on:
      mariadb: {condition: service_healthy}
      redis: {condition: service_healthy}
    logging: *default-logging

  caddy:
    image: $CADDY_IMAGE
    restart: always
    ports:
      - "$HTTPS_PORT:443"
    volumes:
      - "$CONFIG_DIR/Caddyfile:/etc/caddy/Caddyfile:ro"
      - nextcloud_data:/var/www/html:ro
      - caddy_data:/data
      - caddy_config:/config
    networks: [nextcloud_network]
    environment:
      - SERVER_IP=$SERVER_IP
      - HTTPS_PORT=$HTTPS_PORT
      - CADDY_ADMIN=0.0.0.0:2019
    command: sh -c "caddy run --config /etc/caddy/Caddyfile --adapter caddyfile"
    healthcheck:
      test: ["CMD-SHELL", "wget --no-verbose --tries=1 --spider http://localhost:2019/config || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s
    depends_on:
      nextcloud: {condition: service_healthy}
    logging: *default-logging

  collabora:
    image: $COLLABORA_IMAGE
    restart: always
    cap_add: [CAP_SYS_ADMIN, CAP_MKNOD]
    security_opt: [seccomp:unconfined]
    environment:
      - domain=$SERVER_IP
      - username=admin
      - password=$COLLABORA_PASSWORD
      - extra_params=--o:ssl.enable=false --o:ssl.termination=true --o:net.hostsallow=all --o:allow-origin=https://$SERVER_IP:$HTTPS_PORT --o:server_name=$SERVER_IP:$HTTPS_PORT
    networks: [nextcloud_network]
    healthcheck:
      test: ["CMD", "curl", "--fail", "--silent", "--output", "/dev/null", "http://localhost:9980/hosting/capabilities"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 120s
    depends_on:
      nextcloud: {condition: service_healthy}
    logging: *default-logging
EOF

  cat > "$CONFIG_DIR/Caddyfile" <<EOF
{
    # 全局配置
    default_sni $SERVER_IP
    servers :443 {
        protocols h1 h2 h3
    }
}

$SERVER_IP:443 {
    # TLS配置
    tls internal

    # 根目录
    root * /var/www/html

    # 文件上传限制
    request_body {
        max_size 10GB
    }

    # 必要的安全头
    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains"
        X-Content-Type-Options "nosniff"
        X-Frame-Options "SAMEORIGIN"
        -Server
    }

    # 压缩
    encode gzip

    # WebDAV重定向
    redir /.well-known/carddav /remote.php/dav/ 301
    redir /.well-known/caldav /remote.php/dav/ 301
    redir /.well-known/webfinger /index.php/.well-known/webfinger 301
    redir /.well-known/nodeinfo /index.php/.well-known/nodeinfo 301

    # 阻止敏感文件
    @forbidden path /.htaccess /data/* /config/* /3rdparty/* /lib/* /templates/* /occ /console.php /updater/* /.user.ini
    respond @forbidden 403

    # OCS API处理（保持简单）
    handle /ocs/v*.php* {
        php_fastcgi nextcloud:9000 {
            dial_timeout 5s
            read_timeout 60s
        }
    }

    # Status和Cron端点
    handle /status.php {
        php_fastcgi nextcloud:9000 {
            dial_timeout 3s
            read_timeout 10s
        }
    }

    handle /cron.php {
        php_fastcgi nextcloud:9000 {
            dial_timeout 5s
            read_timeout 600s  # 10分钟
        }
    }

    # Collabora代理
    @collabora path /browser/* /hosting/* /cool/* /lool/* /adminws/* /loleaflet/* /wopi/*
    handle @collabora {
        reverse_proxy collabora:9980 {
            header_up Host {upstream_hostport}
            header_up X-Forwarded-Proto https
            header_up X-Forwarded-For {remote_host}

            # 长连接支持
            transport http {
                keepalive 300s
                read_timeout 3600s
                write_timeout 3600s
                dial_timeout 10s
            }
        }
    }

    # WebSocket支持
    @websocket {
        header Connection *Upgrade*
        header Upgrade websocket
    }
    handle @websocket {
        reverse_proxy nextcloud:9000 {
            transport http {
                keepalive 3600s
                read_timeout 3600s
                write_timeout 3600s
            }
        }
    }

    # 静态文件缓存
    @static {
        file
        path *.css *.js *.mjs *.ico *.png *.jpg *.jpeg *.gif *.svg *.woff2 *.woff *.map
    }
    handle @static {
        header Cache-Control "public, max-age=31536000"
        file_server
    }

    # 核心PHP处理
    php_fastcgi nextcloud:9000 {
        index index.php
        dial_timeout 10s
        read_timeout 300s
        write_timeout 300s
    }

    # 日志
    log {
        level INFO
    }
}

# HTTP重定向
http://$SERVER_IP {
    redir https://{host}{uri} 301
}
EOF
}

# 等待Nextcloud就绪
wait_for_nextcloud() {
  info "等待Nextcloud服务就绪..."
  local max_attempts=60
  local attempt=1
  while [ $attempt -le $max_attempts ]; do
    if $DOCKER_COMPOSE_CMD -p nextcloud -f "$CONFIG_DIR/docker-compose.yml" --env-file "$ENV_FILE" exec -T nextcloud php occ status &>/dev/null; then
      info "Nextcloud服务已就绪"
      return 0
    fi
    sleep 5
    attempt=$((attempt + 1))
  done
  error "Nextcloud启动超时，请检查容器日志: $DOCKER_COMPOSE_CMD -p nextcloud logs nextcloud"
}

# 配置Nextcloud集成
configure_nextcloud() {
  info "配置Nextcloud插件..."
  source "$ENV_FILE"
  wait_for_nextcloud

  local occ_cmd="$DOCKER_COMPOSE_CMD -p nextcloud -f $CONFIG_DIR/docker-compose.yml --env-file $ENV_FILE exec -T nextcloud php occ"

  $occ_cmd app:install richdocuments >/dev/null 2>&1 || error "Richdocuments插件安装失败"
  $occ_cmd app:enable richdocuments >/dev/null 2>&1 || error "Richdocuments插件启用失败"
  $occ_cmd config:app:set richdocuments wopi_url --value="collabora:9980" >/dev/null 2>&1
  $occ_cmd config:app:set richdocuments disable_certificate_verification --value="true" >/dev/null 2>&1
  $occ_cmd config:app:set richdocuments wopi_allowlist --value="172.19.0.0/16" >/dev/null 2>&1

  $occ_cmd config:system:set memcache.local --value="\\OC\\Memcache\\Redis" >/dev/null 2>&1
  $occ_cmd config:system:set memcache.locking --value="\\OC\\Memcache\\Redis" >/dev/null 2>&1
  $occ_cmd config:system:set redis host --value="redis" >/dev/null 2>&1
  $occ_cmd config:system:set redis port --value="6379" >/dev/null 2>&1
  $occ_cmd config:system:set redis password --value="$REDIS_PASSWORD" >/dev/null 2>&1

  $occ_cmd config:system:set datadirectory --value="/var/www/html/data" >/dev/null 2>&1

  $occ_cmd config:system:set loglevel --value="2" >/dev/null 2>&1 || echo "日志级别配置失败"

  $occ_cmd config:system:set trusted_domains 0 --value="$SERVER_IP:$HTTPS_PORT" >/dev/null 2>&1 || echo "信任域名配置失败"
  $occ_cmd config:system:set trusted_domains 1 --value="127.0.0.1:$HTTPS_PORT" >/dev/null 2>&1 || echo "信任域名配置失败"
  $occ_cmd config:system:set trusted_domains 2 --value="localhost:$HTTPS_PORT" >/dev/null 2>&1 || echo "信任域名配置失败"

  $occ_cmd config:system:set allow_local_remote_servers --type boolean --value true >/dev/null 2>&1
  $occ_cmd config:system:set maintenance_window_start --type integer --value 2 >/dev/null 2>&1
  $occ_cmd config:system:set maintenance_window_end --type integer --value 4 >/dev/null 2>&1

  info "执行系统维护..."
  $occ_cmd maintenance:repair --include-expensive >/dev/null 2>&1 || warning "部分维护操作执行失败"
}

# 服务控制函数
start() {
  info "启动服务..."
  $DOCKER_COMPOSE_CMD -p nextcloud -f "$CONFIG_DIR/docker-compose.yml" --env-file "$ENV_FILE" up -d --wait --wait-timeout 600
  info "服务启动中，正在进行初始化配置..."
  configure_nextcloud
  info "部署完成！访问地址: https://$SERVER_IP:$HTTPS_PORT"
}

stop() {
  info "停止服务..."
  $DOCKER_COMPOSE_CMD -p nextcloud -f "$CONFIG_DIR/docker-compose.yml" --env-file "$ENV_FILE" down
}

restart() {
  stop
  start
}

# 主流程
main() {
  check_deps
  check_ports
  init_dirs
  gen_env
  gen_configs
  start
}

main "$@"