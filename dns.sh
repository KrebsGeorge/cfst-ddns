#!/bin/bash

# 定义变量
CFSPEED_EXEC="./CloudflareST"
OS_TYPE=$(uname)
ARCH_TYPE=$(uname -m)
CLOUDFLARE_IP_URL="http://dnspod.tk/ip/"
CLOUDFLARE_IP_FILE="Cloudflare.txt"
CONFIG_FILE="config.conf"
RESULT_FILE="result.csv"

# 检查命令是否存在，不存在则自动安装
check_command() {
    if ! command -v "$1" &> /dev/null; then
        echo "命令 $1 不存在，正在安装..."
        if [[ "$OS_TYPE" == "Linux" ]]; then
            if [[ -f /etc/os-release ]]; then
                . /etc/os-release
                if [[ "$ID" == "openwrt" ]]; then
                    opkg update && opkg install "$2"
                else
                    if command -v apt &> /dev/null; then
                     apt update && apt install -y "$2"
                    elif command -v yum &> /dev/null; then
                        yum install -y "$2"
                    fi
                fi
            fi
        elif [[ "$OS_TYPE" == "Darwin" ]]; then
            brew install "$2"
        fi
    fi
}

# 检查必要命令
check_command curl curl
check_command jq jq
check_command awk gawk

# 下载 CloudflareSpeedTest 函数
download_speedtest() {
    echo "CloudflareSpeedTest 不存在，开始下载..."
    
    if [[ "$OS_TYPE" == "Darwin" ]]; then
        if [[ "$ARCH_TYPE" == "arm64" ]]; then
            DOWNLOAD_URL="https://github.com/ShadowObj/CloudflareSpeedTest/releases/download/v2.2.6/CloudflareSpeedtest_darwin_arm64"
        else
            DOWNLOAD_URL="https://github.com/ShadowObj/CloudflareSpeedTest/releases/download/v2.2.6/CloudflareSpeedtest_darwin_amd64"
        fi
    elif [[ "$OS_TYPE" == "Linux" ]]; then
        if [[ "$ARCH_TYPE" == "aarch64" ]]; then
            DOWNLOAD_URL="https://github.com/ShadowObj/CloudflareSpeedTest/releases/download/v2.2.6/CloudflareSpeedtest_linux_arm64"
        else
            DOWNLOAD_URL="https://github.com/ShadowObj/CloudflareSpeedTest/releases/download/v2.2.6/CloudflareSpeedtest_linux_amd64"
        fi
    elif [[ "$OS_TYPE" =~ MINGW|MSYS|CYGWIN ]]; then
        if [[ "$ARCH_TYPE" == "arm64" ]]; then
            DOWNLOAD_URL="https://github.com/ShadowObj/CloudflareSpeedTest/releases/download/v2.2.6/CloudflareSpeedtest_win_arm64.exe"
        else
            DOWNLOAD_URL="https://github.com/ShadowObj/CloudflareSpeedTest/releases/download/v2.2.6/CloudflareSpeedtest_win_amd64.exe"
        fi
    else
        echo "不支持的操作系统或架构: $OS_TYPE $ARCH_TYPE"
        exit 1
    fi

    curl -Lo "$CFSPEED_EXEC" "$DOWNLOAD_URL"
    if [[ $? -ne 0 ]]; then
        echo "下载失败，请检查网络连接。"
        exit 1
    fi
    chmod +x "$CFSPEED_EXEC"
}
# 欢迎界面
echo "=============================================="
echo " 欢迎使用 全自动优选工具"
echo "=============================================="
# 配置输入函数
read_configuration() {
    read -p "请输入 Cloudflare 账户邮箱 [当前值: ${AUTH_EMAIL:-未设置}]: " AUTH_EMAIL_INPUT
    AUTH_EMAIL=${AUTH_EMAIL_INPUT:-${AUTH_EMAIL}}
    read -p "请输入 Cloudflare Global API Key [当前值: ${AUTH_KEY:-未设置}]: " AUTH_KEY_INPUT
    AUTH_KEY=${AUTH_KEY_INPUT:-${AUTH_KEY}}
    
    # 首先输入域名
    read -p "请输入需要更新的域名（例如 yourdomain.com）[当前值: ${DOMAIN:-未设置}]: " DOMAIN_INPUT
    DOMAIN=${DOMAIN_INPUT:-${DOMAIN}}
    
    # 然后输入主机名
    read -p "请输入主机名（例如 www，如果留空则表示根域）[当前值: ${HOSTNAME:-未设置}]: " HOSTNAME_INPUT
    HOSTNAME=${HOSTNAME_INPUT:-${HOSTNAME}}
    
    # 根据主机名和域名拼接子域名
    if [[ -z "$HOSTNAME" ]]; then
        SUBDOMAIN="$DOMAIN"
    else
        SUBDOMAIN="${HOSTNAME}.${DOMAIN}"
    fi

    read -p "请输入测试数量（默认值: ${DN_COUNT:-10}）: " DN_COUNT_INPUT
    DN_COUNT=${DN_COUNT_INPUT:-${DN_COUNT:-10}}
    read -p "请输入地区（默认值: ${CFCOLO:-HKG}）: " CFCOLO_INPUT
    CFCOLO=${CFCOLO_INPUT:-${CFCOLO:-HKG}}
    read -p "请输入端口（默认值: ${PORT:-443}）: " PORT_INPUT
    PORT=${PORT_INPUT:-${PORT:-443}}
    
    # 保存配置
    cat <<EOT > "$CONFIG_FILE"
AUTH_EMAIL="$AUTH_EMAIL"
AUTH_KEY="$AUTH_KEY"
DOMAIN="$DOMAIN"
HOSTNAME="$HOSTNAME"
SUBDOMAIN="$SUBDOMAIN"
DN_COUNT="$DN_COUNT"
CFCOLO="$CFCOLO"
PORT="$PORT"
EOT
}

# 获取 Zone ID，首次获取后保存到配置文件
get_zone_id() {
    if [[ -z "$ZONE_ID" ]]; then
        ZONE_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=${DOMAIN}" \
             -H "X-Auth-Email: ${AUTH_EMAIL}" \
             -H "X-Auth-Key: ${AUTH_KEY}" \
             -H "Content-Type: application/json" | jq -r '.result[0].id')
        
        if [[ -z "$ZONE_ID" || "$ZONE_ID" == "null" ]]; then
          echo "无法获取 Zone ID，请检查域名和认证信息。"
          echo "这里报错大概率是JQ没有安装根据自己的系统安装即可不会请Google。"

          exit 1
        fi

        # 将 Zone ID 添加到配置文件
        echo "ZONE_ID=\"$ZONE_ID\"" >> "$CONFIG_FILE"
    fi
}

# 检查并下载 CloudflareSpeedTest
if [[ ! -f "$CFSPEED_EXEC" ]]; then
    download_speedtest
fi

# 下载 Cloudflare IP 列表
echo "下载 Cloudflare IP 列表..."
curl -o "$CLOUDFLARE_IP_FILE" "$CLOUDFLARE_IP_URL"
if [[ $? -ne 0 ]]; then
    echo "下载 Cloudflare IP 列表失败。"
    exit 1
fi
echo "Cloudflare IP 列表已保存到 $CLOUDFLARE_IP_FILE"

# 检查参数并加载配置文件
if [[ "$1" == "r" ]]; then
    echo "重新填写配置..."
    read_configuration
elif [[ -f "$CONFIG_FILE" ]]; then
    echo "检测到配置文件，自动加载配置。"
    source "$CONFIG_FILE"
else
    echo "配置文件不存在，将引导输入配置。"
    read_configuration
fi

# 获取并保存 Zone ID
get_zone_id

# 运行 CloudflareSpeedTest
echo "运行 CloudflareSpeedTest..."
"$CFSPEED_EXEC" -dn "$DN_COUNT" -sl 1 -tl 1000 -cfcolo "$CFCOLO" -f "$CLOUDFLARE_IP_FILE" -tp "$PORT"
if [[ $? -ne 0 ]]; then
    echo "CloudflareSpeedTest 执行失败，请检查执行权限或文件是否正确。"
    exit 1
fi
echo "CloudflareSpeedTest 任务完成！"

# 找到最快的 IP
BEST_IP=$(awk -F, 'NR > 1 { if($6 > max) { max = $6; best_ip = $1 }} END { print best_ip }' "$RESULT_FILE")
if [[ -z "$BEST_IP" ]]; then
    echo "未找到有效的最佳 IP 地址。"
    exit 1
fi

# 获取 DNS Record ID
RECORD_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records?type=A&name=${SUBDOMAIN}" \
     -H "X-Auth-Email: ${AUTH_EMAIL}" \
     -H "X-Auth-Key: ${AUTH_KEY}" \
     -H "Content-Type: application/json" | jq -r '.result[0].id')
if [[ -z "$RECORD_ID" || "$RECORD_ID" == "null" ]]; then
  echo "无法获取 DNS Record ID，请检查子域名是否存在。"
  exit 1
fi

# 更新 DNS 记录
UPDATE_RESULT=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records/${RECORD_ID}" \
     -H "X-Auth-Email: ${AUTH_EMAIL}" \
     -H "X-Auth-Key: ${AUTH_KEY}" \
     -H "Content-Type: application/json" \
     --data '{
       "type": "A",
       "name": "'"${SUBDOMAIN}"'",
       "content": "'"${BEST_IP%%:*}"'",
       "ttl": 120,
       "proxied": false
     }' | jq -r '.success')
if [[ "$UPDATE_RESULT" == "true" ]]; then
  echo "DNS 记录更新成功：${SUBDOMAIN} -> ${BEST_IP%%:*}"
else
  echo "DNS 记录更新失败，请检查日志。"
fi
