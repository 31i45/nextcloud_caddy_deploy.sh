#!/bin/bash
# 极简版Nextcloud部署脚本 - 极致极简、极致克制、极致可靠
# groups | grep docker
# sudo usermod -aG docker $USER
set -euo pipefail

# ---------------------- 配置部分 ----------------------
PROJECT_DIR="$HOME/nextcloud"
CONFIG_DIR="$PROJECT_DIR/configs"
ENV_FILE="$CONFIG_DIR/.env"
mkdir -p "$CONFIG_DIR"

# ---------------------- 环境变量处理 ----------------------

# 生成随机密码
generate_password() {
  tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16
}

if [ ! -f "$ENV_FILE" ]; then
  cat > "$ENV_FILE" <<EOF
SERVER_IP="$(hostname -I | cut -d' ' -f1 || echo "127.0.0.1")"
HTTPS_PORT="18443"
ADMIN_USER="admin"
ADMIN_PASSWORD="$(generate_password)"
MYSQL_PASSWORD="$(generate_password)"
MYSQL_ROOT_PASSWORD="$(generate_password)"
REDIS_PASSWORD="$(generate_password)"
COLLABORA_PASSWORD="$(generate_password)"
EOF
  # 添加权限设置，仅允许文件所有者读写
  chmod 600 "$ENV_FILE"
fi
# 直接使用shell方式加载环境变量
if [ -f "$ENV_FILE" ]; then
  source "$ENV_FILE"
fi

# ---------------------- 函数定义 ----------------------

# Docker Compose命令
dc() {
  if command -v docker-compose >/dev/null 2>&1; then
    docker-compose "$@"
  else
    docker compose "$@"
  fi
}

# 执行Nextcloud occ命令
occ() {
  dc -p nextcloud -f "$CONFIG_DIR/docker-compose.yml" exec -T nextcloud php occ "$@"
}

# 配置Nextcloud
config_nextcloud() {
  
  # ---------------------- 核心性能配置 ----------------------
  # 配置Redis缓存和文件锁定，提升性能
  occ config:system:set memcache.local --value="\\OC\\Memcache\\Redis" >/dev/null 2>&1 || echo "Redis本地缓存配置失败"
  occ config:system:set memcache.locking --value="\\OC\\Memcache\\Redis" >/dev/null 2>&1 || echo "Redis锁缓存配置失败"
  occ config:system:set redis host --value="redis" >/dev/null 2>&1 || echo "Redis主机配置失败"
  occ config:system:set redis port --value="6379" >/dev/null 2>&1 || echo "Redis端口配置失败"
  occ config:system:set redis password --value="$REDIS_PASSWORD" >/dev/null 2>&1 || echo "Redis密码配置失败"
  
  # 必须配置：优化文件系统检查
  occ config:system:set filesystem_check_changes --type boolean --value false >/dev/null 2>&1 || echo "文件系统检查配置失败"
  
  # 必须配置：启用完整UTF-8支持
  occ config:system:set mysql.utf8mb4 --type boolean --value true >/dev/null 2>&1 || echo "MySQL UTF8MB4配置失败"
  
  # 推荐配置：优化文件缓存
  occ config:system:set filecache.ttl --type integer --value 3600 >/dev/null 2>&1 || echo "文件缓存TTL配置失败"
  
  # 必须配置：优化预览生成
  occ config:system:set preview_max_x --type integer --value 2048 >/dev/null 2>&1 || echo "预览最大宽度配置失败"
  occ config:system:set preview_max_y --type integer --value 2048 >/dev/null 2>&1 || echo "预览最大高度配置失败"
  occ config:system:set preview_max_filesize_image --type integer --value 50 >/dev/null 2>&1 || echo "图片预览文件大小限制配置失败"
  
  # ---------------------- 核心安全配置 ----------------------
  # 禁用不受支持的应用
  occ config:system:set disable_unsupported_apps --type boolean --value true >/dev/null 2>&1 || echo "禁用不受支持的应用配置失败"
  
  # ---------------------- 核心功能配置 ----------------------
  # 启用外部存储支持
  occ app:enable files_external >/dev/null 2>&1 || echo "外部存储应用启用失败"

  # 设置默认电话号码区域
  occ config:system:set default_phone_region --value='CN' >/dev/null 2>&1 || echo "默认电话号码区域配置失败"
  
  # 安装并配置Collabora集成 - 完整配置
  occ app:install richdocuments >/dev/null 2>&1 || echo "Richdocuments插件安装失败"
  occ app:enable richdocuments >/dev/null 2>&1 || echo "Richdocuments插件启用失败"
  
  occ config:app:set richdocuments wopi_url --value="http://collabora:9980" >/dev/null 2>&1 || echo "Collabora WOPI URL配置失败"
  occ config:app:set richdocuments disable_certificate_verification --value="true" >/dev/null 2>&1 || echo "Collabora证书验证配置失败"
  occ config:app:set richdocuments wopi_allowlist --value="172.19.0.0/16" >/dev/null 2>&1 || echo "Collabora WOPI白名单配置失败"
  
  # 配置支持所有Office文档格式 - 最完整的格式列表
  occ config:app:set richdocuments formats --value='["odt","ods","odp","docx","xlsx","pptx","doc","xls","ppt","txt","rtf","csv","tsv","html","htm","epub","pdf","odg","odf","odb","ots","ott","otp","oth","xlsm","xltx","xlsm","xlsb","pptm","potx","potm","ppsx","ppsm","dotx","dotm","rtfd","wps","wks","wpd","sxc","stc","sxd","std","sxi","sti","sxm","sdw","sgl","vor","uop","uof","zabw","zot"]' >/dev/null 2>&1 || echo "Office文档格式配置失败"
  
  # 启用编辑功能
  occ config:app:set richdocuments edit --value="true" >/dev/null 2>&1 || echo "编辑功能启用失败"
  
  # 配置文档预览
  occ config:app:set richdocuments preview_office_files --value="true" >/dev/null 2>&1 || echo "Office文档预览配置失败"
  
  # 配置默认编辑器
  occ config:app:set richdocuments default_editor --value="collabora" >/dev/null 2>&1 || echo "默认编辑器配置失败"
  
  # ---------------------- 系统可靠性配置 ----------------------
  # 配置维护窗口
  occ config:system:set maintenance_window_start --type integer --value 2 >/dev/null 2>&1 || echo "维护窗口开始时间配置失败"
  occ config:system:set maintenance_window_end --type integer --value 4 >/dev/null 2>&1 || echo "维护窗口结束时间配置失败"
  
  # 执行mimetype迁移
  occ maintenance:repair --include-expensive >/dev/null 2>&1 || echo "维护修复（包含昂贵操作）失败"
  
  # 配置日志级别
  occ config:system:set loglevel --value="2" >/dev/null 2>&1 || echo "日志级别配置失败"
  
  # ---------------------- 信任域名配置 ----------------------
  # 配置信任域名，支持多种访问方式
  occ config:system:set trusted_domains 0 --value="$SERVER_IP:$HTTPS_PORT" >/dev/null 2>&1 || echo "信任域名（服务器IP）配置失败"
  occ config:system:set trusted_domains 1 --value="127.0.0.1:$HTTPS_PORT" >/dev/null 2>&1 || echo "信任域名（本地回环）配置失败"
  occ config:system:set trusted_domains 2 --value="localhost:$HTTPS_PORT" >/dev/null 2>&1 || echo "信任域名（本地主机）配置失败"
  occ config:system:set trusted_proxies 0 --value='172.19.0.0/16' >/dev/null 2>&1 || echo "信任代理配置失败"

  # ---------------------- 禁用不必要的应用 ----------------------
  # 禁用首次运行向导
  occ app:disable firstrunwizard >/dev/null 2>&1 || echo "首次运行向导禁用失败"
  
  # 禁用默认应用
  occ app:disable calendar >/dev/null 2>&1 || echo "日历应用禁用失败"
  occ app:disable contacts >/dev/null 2>&1 || echo "联系人应用禁用失败"
  occ app:disable activity >/dev/null 2>&1 || echo "活动应用禁用失败"
  occ app:disable gallery >/dev/null 2>&1 || echo "画廊应用禁用失败"
}

# ---------------------- 配置文件生成 ----------------------

# 生成docker-compose.yml
cat > "$CONFIG_DIR/docker-compose.yml" <<EOF
volumes:
  # nextcloud_data: # 可改为指向其他磁盘或目录，示例配置：
  #   name: nextcloud_data
  #   driver: local
  #   driver_opts:
  #     type: none
  #     o: bind
  #     device: /path/to/your/disk
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
  default:
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
    command: --transaction-isolation=READ-COMMITTED --binlog-format=ROW --innodb_buffer_pool_size=256M --innodb_log_file_size=64M
    networks: [default]
    healthcheck:
      test: ["CMD", "mariadb-admin", "ping", "-h", "localhost", "-u", "root", "-p$MYSQL_ROOT_PASSWORD"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 60s
    deploy:
      resources:
        limits:
          cpus: '1.0'
          memory: 1G
        reservations:
          cpus: '0.5'
          memory: 512M
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

  redis:
    image: redis:alpine
    restart: always
    volumes: [redis_data:/data]
    command: redis-server --requirepass $REDIS_PASSWORD --maxmemory 256mb --maxmemory-policy allkeys-lru
    networks: [default]
    healthcheck:
      test: ["CMD", "redis-cli", "-u", "redis://default:$REDIS_PASSWORD@localhost:6379", "PING"]
      interval: 5s
      timeout: 3s
      retries: 3
      start_period: 10s
    deploy:
      resources:
        limits:
          cpus: '0.5'
          memory: 512M
        reservations:
          cpus: '0.25'
          memory: 256M
    logging:
      driver: "json-file"
      options:
        max-size: "5m"
        max-file: "2"

  nextcloud:
    image: nextcloud:production-fpm-alpine
    restart: always
    volumes:
      - nextcloud_data:/var/www/html
      - type: tmpfs
        target: /tmp
        tmpfs:
          size: 128M
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
    networks: [default]
    healthcheck:
      test: ["CMD-SHELL", "php /var/www/html/occ status | grep -q 'installed: true' || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 180s
    deploy:
      resources:
        limits:
          cpus: '2.0'
          memory: 2G
        reservations:
          cpus: '1.0'
          memory: 1G
    logging:
      driver: "json-file"
      options:
        max-size: "20m"
        max-file: "5"
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
    networks: [default]
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
    deploy:
      resources:
        limits:
          cpus: '0.5'
          memory: 512M
        reservations:
          cpus: '0.25'
          memory: 256M
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
    depends_on:
      nextcloud: {condition: service_healthy}

  collabora:
    image: collabora/code:latest # 25.04.7.3.1
    restart: always
    cap_add: [CAP_SYS_ADMIN, CAP_MKNOD]
    security_opt: [seccomp:unconfined]
    environment:
      domain: $SERVER_IP:$HTTPS_PORT # 包含端口号，确保正确识别Nextcloud实例
      username: admin
      password: $COLLABORA_PASSWORD
      dictionaries: en_US en_GB fr_FR de_DE es_ES pt_BR ru_RU zh_CN # 支持多语言拼写检查
      extra_params: --o:ssl.enable=false --o:ssl.termination=true --o:net.hostsallow=all --o:allow-origin=https://$SERVER_IP:$HTTPS_PORT --o:server_name=$SERVER_IP:$HTTPS_PORT --o:storage.wopi.host.enable=true --o:collabora.enable=true --o:user_interface.default_language=zh-CN --o:user_interface.show_warning_banner=false
    networks: [default]
    healthcheck:
      test: ["CMD", "curl", "--fail", "--silent", "--output", "/dev/null", "http://localhost:9980/hosting/capabilities"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 120s
    deploy:
      resources:
        limits:
          cpus: '2.0'
          memory: 2G
        reservations:
          cpus: '1.0'
          memory: 1G
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
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
        Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-eval' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'self' ws: wss:; frame-src 'self' collabora:; object-src 'none';"
    }

    # 压缩
    encode gzip zstd

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
        format json
        output file /var/log/caddy/access.log {
          roll_size 10mb
          roll_keep 5
          roll_keep_for 720h
        }
    }
}

# HTTP重定向 - 使用80端口
:80 {
  redir https://{host}:$HTTPS_PORT{uri} 301
}
EOF

# ---------------------- 主部署流程 ----------------------

echo "========================================"
echo "开始部署 Nextcloud 服务..."
echo "========================================"

# 部署服务，使用 --quiet-pull 减少输出
# 使用 --wait 确保所有服务就绪
dc -p nextcloud -f "$CONFIG_DIR/docker-compose.yml" up -d --wait --quiet-pull
if [ $? -ne 0 ]; then
  echo "   警告：部分服务未就绪，但脚本将继续执行..."
fi

echo -e "\n配置 Nextcloud..."
if config_nextcloud; then
  echo "✅ Nextcloud 配置完成！"
else
  echo "⚠️ 注意：部分配置可能失败，请检查日志"
fi

echo -e "\n========================================"
echo "🎉 部署完成！"
echo "========================================"
echo "访问地址: https://$SERVER_IP:$HTTPS_PORT"
echo "管理员账号: $ADMIN_USER"
echo "管理员密码: $ADMIN_PASSWORD"
echo ""
echo "📋 后续建议："
echo "1. 首次访问需要接受自签名证书"
echo "2. 登录后建议修改默认密码"
echo "3. 定期备份数据目录和数据库"
echo "4. 关注 Nextcloud 官方安全更新"
echo "========================================"