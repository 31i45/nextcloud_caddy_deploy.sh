#!/bin/bash
# 极简版Nextcloud部署脚本 - 极致极简、极致克制、极致可靠
# groups | grep docker
# sudo usermod -aG docker $USER
set -e

# ---------------------- 配置部分 ----------------------
PROJECT_DIR="${1:-$HOME/nextcloud}"
CONFIG_DIR="$PROJECT_DIR/configs"
ENV_FILE="$CONFIG_DIR/.env"
HTTPS_PORT=${HTTPS_PORT:-18443}
SERVER_IP=$(hostname -I | cut -d' ' -f1 || echo "127.0.0.1")
mkdir -p "$CONFIG_DIR"

# ---------------------- 函数定义 ----------------------

# 生成随机密码
generate_password() {
  tr -dc A-Za-z0-9 </dev/urandom | head -c 12
}

# Docker Compose命令
dc() {
  command -v docker-compose >/dev/null && docker-compose "$@" || docker compose "$@"
}

# 等待Nextcloud就绪
wait_nextcloud() {
  local max_attempts=120
  local attempt=1
  while [ $attempt -le $max_attempts ]; do
    echo "等待Nextcloud就绪..."
    if dc -p nextcloud -f "$CONFIG_DIR/docker-compose.yml" exec -T nextcloud php occ status &>/dev/null; then
      return 0
    fi
    sleep 5
    attempt=$((attempt + 1))
  done
  return 1
}

# 配置Nextcloud
config_nextcloud() {
  local occ="dc -p nextcloud -f \"$CONFIG_DIR/docker-compose.yml\" exec -T nextcloud php occ"
  
  # 安装并配置Collabora集成
  $occ app:install richdocuments >/dev/null 2>&1 || echo "Richdocuments插件安装失败"
  $occ app:enable richdocuments >/dev/null 2>&1 || echo "Richdocuments插件启用失败"
  $occ config:app:set richdocuments wopi_url --value="http://collabora:9980" >/dev/null 2>&1
  $occ config:app:set richdocuments disable_certificate_verification --value="true" >/dev/null 2>&1
  $occ config:app:set richdocuments wopi_allowlist --value="172.19.0.0/16" >/dev/null 2>&1
  
  # 配置系统设置，提升可靠性
  $occ config:system:set allow_local_remote_servers --type boolean --value true >/dev/null 2>&1
  $occ config:system:set maintenance_window_start --type integer --value 2 >/dev/null 2>&1
  $occ config:system:set maintenance_window_end --type integer --value 4 >/dev/null 2>&1
  
  # 配置Redis缓存和文件锁定，提升性能和可靠性
  $occ config:system:set memcache.local --value="\\OC\\Memcache\\Redis" >/dev/null 2>&1
  $occ config:system:set memcache.locking --value="\\OC\\Memcache\\Redis" >/dev/null 2>&1
  $occ config:system:set redis host --value="redis" >/dev/null 2>&1
  $occ config:system:set redis port --value="6379" >/dev/null 2>&1
  $occ config:system:set redis password --value="$REDIS_PASSWORD" >/dev/null 2>&1
  
  # 配置默认存储位置
  $occ config:system:set datadirectory --value="/var/www/html/data" >/dev/null 2>&1
  
  # 配置日志级别，2表示警告级别，减少日志量
  $occ config:system:set loglevel --value="2" >/dev/null 2>&1 || echo "日志级别配置失败"
  
  # 配置更多信任域名，支持多种访问方式
  $occ config:system:set trusted_domains 0 --value="$SERVER_IP:$HTTPS_PORT" >/dev/null 2>&1 || echo "信任域名配置失败"
  $occ config:system:set trusted_domains 1 --value="127.0.0.1:$HTTPS_PORT" >/dev/null 2>&1 || echo "信任域名配置失败"
  $occ config:system:set trusted_domains 2 --value="localhost:$HTTPS_PORT" >/dev/null 2>&1 || echo "信任域名配置失败"
}

# ---------------------- 环境变量处理 ----------------------

if [ ! -f "$ENV_FILE" ]; then
  cat > "$ENV_FILE" <<EOF
ADMIN_USER=${ADMIN_USER:-admin}
ADMIN_PASSWORD=${ADMIN_PASS:-$(generate_password)}
MYSQL_PASSWORD=$(generate_password)
MYSQL_ROOT_PASSWORD=$(generate_password)
REDIS_PASSWORD=$(generate_password)
COLLABORA_PASSWORD=$(generate_password)
SERVER_IP=$SERVER_IP
HTTPS_PORT=$HTTPS_PORT
EOF
fi
source "$ENV_FILE"

# ---------------------- 配置文件生成 ----------------------

# 生成docker-compose.yml
cat > "$CONFIG_DIR/docker-compose.yml" <<EOF
volumes:
  nextcloud_data:
    name: nextcloud_data
  mariadb_data:
    name: nextcloud_mariadb_data
  redis_data:
    name: nextcloud_redis_data
  caddy_data:
    name: nextcloud_caddy_data
  caddy_config:
    name: nextcloud_caddy_config

networks:
  nextcloud_network:
    driver: bridge
    ipam:
      config:
        - subnet: 172.19.0.0/16

services:
  mariadb:
    image: mariadb:11.4
    restart: always
    volumes: [mariadb_data:/var/lib/mysql]
    environment:
      MYSQL_ROOT_PASSWORD: $MYSQL_ROOT_PASSWORD
      MYSQL_DATABASE: nextcloud
      MYSQL_USER: nextcloud
      MYSQL_PASSWORD: $MYSQL_PASSWORD
    command: --transaction-isolation=READ-COMMITTED --binlog-format=ROW
    networks: [nextcloud_network]
    healthcheck:
      test: ["CMD", "mariadb-admin", "ping", "-h", "localhost", "-u", "root", "-p$MYSQL_ROOT_PASSWORD"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 60s

  redis:
    image: redis:alpine
    restart: always
    volumes: [redis_data:/data]
    command: redis-server --requirepass $REDIS_PASSWORD --save 60 1
    networks: [nextcloud_network]
    healthcheck:
      test: ["CMD", "redis-cli", "-u", "redis://default:$REDIS_PASSWORD@localhost:6379", "PING"]
      interval: 5s
      timeout: 3s
      retries: 3
      start_period: 10s

  nextcloud:
    image: nextcloud:production-fpm-alpine
    restart: always
    volumes: [nextcloud_data:/var/www/html]
    environment:
      MYSQL_DATABASE: nextcloud
      MYSQL_USER: nextcloud
      MYSQL_PASSWORD: $MYSQL_PASSWORD
      MYSQL_HOST: mariadb
      NEXTCLOUD_ADMIN_USER: $ADMIN_USER
      NEXTCLOUD_ADMIN_PASSWORD: $ADMIN_PASSWORD
      REDIS_HOST: redis
      REDIS_HOST_PASSWORD: $REDIS_PASSWORD
      NEXTCLOUD_TRUSTED_DOMAINS: $SERVER_IP:$HTTPS_PORT
      NEXTCLOUD_TRUSTED_PROXIES: 172.19.0.0/16
      OVERWRITEHOST: $SERVER_IP:$HTTPS_PORT
      OVERWRITEPROTOCOL: https
      OVERWRITECLIURL: https://$SERVER_IP:$HTTPS_PORT
      PHP_MEMORY_LIMIT: 1024M
      PHP_UPLOAD_LIMIT: 10G
      PHP_MAX_EXECUTION_TIME: 3600
      PHP_MAX_INPUT_VARS: 10000
      TZ: Asia/Shanghai
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

  caddy:
    image: caddy:2.10.0-alpine
    restart: always
    ports: [80:80, $HTTPS_PORT:443]
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

  collabora:
    image: collabora/code:latest
    restart: always
#    cap_add: [CAP_SYS_ADMIN, CAP_MKNOD]
    security_opt: [seccomp:unconfined]
    environment:
      domain: $SERVER_IP
      username: admin
      password: $COLLABORA_PASSWORD
      extra_params: --o:ssl.enable=false --o:ssl.termination=true --o:net.hostsallow=all --o:allow-origin=https://$SERVER_IP:$HTTPS_PORT --o:server_name=$SERVER_IP:$HTTPS_PORT
    networks: [nextcloud_network]
    healthcheck:
      test: ["CMD", "curl", "--fail", "--silent", "--output", "/dev/null", "http://localhost:9980/hosting/capabilities"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 120s
    depends_on:
      nextcloud: {condition: service_healthy}
EOF

# 生成Caddyfile
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

    # OCS API处理
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

    # Collabora WebSocket支持 - 优先级高于通用WebSocket
    @collabora_ws {
        path /cool/* /lool/* /adminws/*
        header Connection *Upgrade*
        header Upgrade websocket
    }
    handle @collabora_ws {
        reverse_proxy collabora:9980 {
            transport http {
                keepalive 3600s
                read_timeout 3600s
                write_timeout 3600s
            }
        }
    }

    # 通用WebSocket支持
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

# HTTP重定向 - 使用80端口
http://$SERVER_IP {
    redir https://{host}:$HTTPS_PORT{uri} 301
}
EOF

# ---------------------- 主部署流程 ----------------------

echo "部署Nextcloud服务..."
dc -p nextcloud -f "$CONFIG_DIR/docker-compose.yml" up -d
wait_nextcloud || echo "警告：Nextcloud未在预期时间内就绪，但脚本将继续执行..."
echo "配置Nextcloud..."
config_nextcloud

echo ""
echo "部署完成！"
echo "访问地址: https://$SERVER_IP:$HTTPS_PORT"
echo "管理员账号: $ADMIN_USER"
echo "管理员密码: $ADMIN_PASSWORD"
echo ""
echo "注意：首次访问需要接受自签名证书"