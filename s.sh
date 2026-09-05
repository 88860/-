#!/usr/bin/env bash

export LANG=en_US.UTF-8
R='\033[31m'
G='\033[32m'
Y='\033[33m'
B='\033[1;36m'
P='\033[0m'

BP="/usr/local/bin/sing-box"
CD="/etc/sing-box"
CS="${CD}/server.json"
CC="${CD}/client.json"
CR="${CD}/certs"
ND="${CD}/nodes"

if [[ ! -f "/usr/bin/s" || $(readlink "/usr/bin/s") != "/root/s.sh" ]]; then
    ln -sf /root/s.sh /usr/bin/s
    chmod +x /root/s.sh
fi

if [[ "$1" == "RenewTLS" ]]; then
    rn
    exit 0
fi

op() {
    local p=$1 c=${2:-tcp}
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q active; then
        ufw allow "$p/$c" >/dev/null 2>&1
    elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --add-port="$p/$c" >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
    else
        if command -v nft >/dev/null 2>&1; then
            nft add rule inet filter input $c dport "$p" accept >/dev/null 2>&1 || \
            nft add rule ip filter INPUT $c dport "$p" accept >/dev/null 2>&1
        fi
        if command -v iptables >/dev/null 2>&1; then
            iptables -I INPUT -p "$c" --dport "$p" -j ACCEPT >/dev/null 2>&1
        fi
    fi
}

ck() {
    local ds=("curl" "wget" "jq" "socat" "openssl" "cron")
    for d in "${ds[@]}"; do
        if ! command -v "$d" >/dev/null 2>&1; then
            echo -e "${Y}依赖: $d ${P}"
            if command -v apt >/dev/null 2>&1; then
                apt update >/dev/null 2>&1 && apt install -y "$d" >/dev/null 2>&1
            elif command -v yum >/dev/null 2>&1; then
                yum install -y "$d" >/dev/null 2>&1
            fi
        fi
    done
}

dc() {
    local a=$(uname -m)
    if [[ "$a" == "x86_64" || "$a" == "amd64" ]]; then
        if grep -q "avx2" /proc/cpuinfo; then echo "amd64-v3"; else echo "amd64"; fi
    elif [[ "$a" == "aarch64" || "$a" == "arm64" ]]; then
        echo "arm64"
    else
        echo "amd64"
    fi
}

ins() {
    ck
    local c=$(dc)
    local v=$(curl -s -m 5 https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name)
    echo -e "${B}获取内核: ${v} ($c)${P}"
    wget -qO /tmp/sb.tar.gz "https://github.com/SagerNet/sing-box/releases/download/${v}/sing-box-${v#v}-linux-${c}.tar.gz"
    tar -xzf /tmp/sb.tar.gz -C /tmp
    mv /tmp/sing-box-*/sing-box "$BP"
    chmod +x "$BP"
    mkdir -p "$CD" "$CR" "$ND"
    rm -rf /tmp/sb.tar.gz /tmp/sing-box-*
}

ic() {
    local d=$1
    echo -e "${B}申请证书...${P}"
    op 80 tcp
    if [[ ! -f "$HOME/.acme.sh/acme.sh" ]]; then curl -s https://get.acme.sh | sh; fi
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
    systemctl stop sing-box >/dev/null 2>&1
    ~/.acme.sh/acme.sh --issue -d "$d" --standalone -k ec-256
    ~/.acme.sh/acme.sh --installcert -d "$d" --fullchainpath ${CR}/fullchain.cer --keypath ${CR}/private.key --ecc
    if [[ -f "${CR}/fullchain.cer" && -f "${CR}/private.key" ]]; then
        echo "$d" > "${CR}/domain.txt"
        echo -e "${G}证书完成${P}"
        it
    else
        echo -e "${R}证书失败${P}"
        exit 1
    fi
}

it() {
    crontab -l > /tmp/bc.cron 2>/dev/null
    sed -i '/s.sh RenewTLS/d' /tmp/bc.cron
    echo "30 1 * * * /bin/bash /root/s.sh RenewTLS >> /root/ct.log 2>&1" >> /tmp/bc.cron
    crontab /tmp/bc.cron
}

rn() {
    if [[ ! -f "${CR}/domain.txt" ]]; then exit 0; fi
    local d=$(cat "${CR}/domain.txt")
    if [[ -d "$HOME/.acme.sh/${d}_ecc" && -f "$HOME/.acme.sh/${d}_ecc/${d}.cer" ]]; then
        local m=$(stat --format=%z "$HOME/.acme.sh/${d}_ecc/${d}.cer")
        m=$(date +%s -d "${m}")
        local c=$(date +%s)
        local rd=$((90 - (c - m) / 86400))
        if [[ ${rd} -le 1 ]]; then
            systemctl stop sing-box
            "$HOME/.acme.sh/acme.sh" --cron --home "$HOME/.acme.sh"
            "$HOME/.acme.sh/acme.sh" --installcert -d "${d}" --fullchainpath "${CR}/fullchain.cer" --keypath "${CR}/private.key" --ecc
            systemctl start sing-box
        fi
    fi
}

ss() {
    if [[ ! -f "$BP" ]]; then ins; fi
    mkdir -p "$CD" "$CR" "$ND"
    echo -e "${B}=====================================${P}"
    echo "1. VLESS-Reality-Vision"
    echo "2. VLESS-Reality-gRPC"
    echo "3. VLESS-TCP-TLS-Vision"
    echo "4. VLESS-WS-TLS"
    echo "5. VMess-WS-TLS"
    echo "6. VMess-HTTPUpgrade-TLS"
    echo "7. Trojan-TCP-TLS"
    echo "8. Hysteria2"
    echo "9. TUIC"
    echo "10. SOCKS5"
    echo -e "${B}=====================================${P}"
    read -r -p "选择: " pc
    
    local pt=$((RANDOM % 20000 + 10000))
    local ud=$($BP generate uuid)
    local ip=$(curl -s4 -m 5 ip.sb)
    local co=""
    local si=""

    op $pt tcp
    op $pt udp

    if [[ "$pc" =~ ^[3-9]$ ]]; then
        read -r -p "解析到本机的域名: " dm
        ic "$dm"
    fi

    case "$pc" in
        1)
            local ks=$($BP generate reality-keypair)
            local pk=$(echo "$ks" | grep PrivateKey | awk '{print $2}'); local pb=$(echo "$ks" | grep PublicKey | awk '{print $2}')
            si="{\"type\": \"vless\",\"listen\": \"::\",\"listen_port\": $pt,\"users\": [{\"uuid\": \"$ud\",\"flow\": \"xtls-rprx-vision\"}],\"tls\": {\"enabled\": true,\"server_name\": \"www.microsoft.com\",\"reality\": {\"enabled\": true,\"handshake\": {\"server\": \"www.microsoft.com\",\"server_port\": 443},\"private_key\": \"$pk\",\"short_id\": [\"\",\"6ba85179e30d4fc2\"]}}}"
            co="{\"type\": \"vless\",\"tag\": \"proxy\",\"server\": \"$ip\",\"server_port\": $pt,\"uuid\": \"$ud\",\"flow\": \"xtls-rprx-vision\",\"tls\": {\"enabled\": true,\"server_name\": \"www.microsoft.com\",\"utls\": {\"enabled\": true,\"fingerprint\": \"chrome\"},\"reality\": {\"enabled\": true,\"public_key\": \"$pb\",\"short_id\": \"6ba85179e30d4fc2\"}}}"
            ;;
        2)
            local ks=$($BP generate reality-keypair)
            local pk=$(echo "$ks" | grep PrivateKey | awk '{print $2}'); local pb=$(echo "$ks" | grep PublicKey | awk '{print $2}')
            si="{\"type\": \"vless\",\"listen\": \"::\",\"listen_port\": $pt,\"users\": [{\"uuid\": \"$ud\"}],\"transport\": {\"type\": \"grpc\",\"service_name\": \"grpc\"},\"tls\": {\"enabled\": true,\"server_name\": \"www.microsoft.com\",\"reality\": {\"enabled\": true,\"handshake\": {\"server\": \"www.microsoft.com\",\"server_port\": 443},\"private_key\": \"$pk\",\"short_id\": [\"\",\"6ba85179e30d4fc2\"]}}}"
            co="{\"type\": \"vless\",\"tag\": \"proxy\",\"server\": \"$ip\",\"server_port\": $pt,\"uuid\": \"$ud\",\"transport\": {\"type\": \"grpc\",\"service_name\": \"grpc\"},\"tls\": {\"enabled\": true,\"server_name\": \"www.microsoft.com\",\"utls\": {\"enabled\": true,\"fingerprint\": \"chrome\"},\"reality\": {\"enabled\": true,\"public_key\": \"$pb\",\"short_id\": \"6ba85179e30d4fc2\"}}}"
            ;;
        3)
            si="{\"type\": \"vless\",\"listen\": \"::\",\"listen_port\": $pt,\"users\": [{\"uuid\": \"$ud\",\"flow\": \"xtls-rprx-vision\"}],\"tls\": {\"enabled\": true,\"server_name\": \"$dm\",\"certificate_path\": \"${CR}/fullchain.cer\",\"key_path\": \"${CR}/private.key\"}}"
            co="{\"type\": \"vless\",\"tag\": \"proxy\",\"server\": \"$dm\",\"server_port\": $pt,\"uuid\": \"$ud\",\"flow\": \"xtls-rprx-vision\",\"tls\": {\"enabled\": true,\"server_name\": \"$dm\",\"utls\": {\"enabled\": true,\"fingerprint\": \"chrome\"}}}"
            ;;
        4)
            local ph="/$(tr -dc 'a-z0-9' </dev/urandom | head -c 6)ws"
            si="{\"type\": \"vless\",\"listen\": \"::\",\"listen_port\": $pt,\"users\": [{\"uuid\": \"$ud\"}],\"transport\": {\"type\": \"ws\",\"path\": \"$ph\"},\"tls\": {\"enabled\": true,\"server_name\": \"$dm\",\"certificate_path\": \"${CR}/fullchain.cer\",\"key_path\": \"${CR}/private.key\"}}"
            co="{\"type\": \"vless\",\"tag\": \"proxy\",\"server\": \"$dm\",\"server_port\": $pt,\"uuid\": \"$ud\",\"transport\": {\"type\": \"ws\",\"path\": \"$ph\"},\"tls\": {\"enabled\": true,\"server_name\": \"$dm\",\"utls\": {\"enabled\": true,\"fingerprint\": \"chrome\"}}}"
            ;;
        5)
            local ph="/$(tr -dc 'a-z0-9' </dev/urandom | head -c 6)vws"
            si="{\"type\": \"vmess\",\"listen\": \"::\",\"listen_port\": $pt,\"users\": [{\"uuid\": \"$ud\",\"alterId\": 0}],\"transport\": {\"type\": \"ws\",\"path\": \"$ph\"},\"tls\": {\"enabled\": true,\"server_name\": \"$dm\",\"certificate_path\": \"${CR}/fullchain.cer\",\"key_path\": \"${CR}/private.key\"}}"
            co="{\"type\": \"vmess\",\"tag\": \"proxy\",\"server\": \"$dm\",\"server_port\": $pt,\"uuid\": \"$ud\",\"security\": \"auto\",\"alter_id\": 0,\"transport\": {\"type\": \"ws\",\"path\": \"$ph\"},\"tls\": {\"enabled\": true,\"server_name\": \"$dm\",\"utls\": {\"enabled\": true,\"fingerprint\": \"chrome\"}}}"
            ;;
        6)
            local ph="/$(tr -dc 'a-z0-9' </dev/urandom | head -c 6)hup"
            si="{\"type\": \"vmess\",\"listen\": \"::\",\"listen_port\": $pt,\"users\": [{\"uuid\": \"$ud\",\"alterId\": 0}],\"transport\": {\"type\": \"httpupgrade\",\"path\": \"$ph\"},\"tls\": {\"enabled\": true,\"server_name\": \"$dm\",\"certificate_path\": \"${CR}/fullchain.cer\",\"key_path\": \"${CR}/private.key\"}}"
            co="{\"type\": \"vmess\",\"tag\": \"proxy\",\"server\": \"$dm\",\"server_port\": $pt,\"uuid\": \"$ud\",\"security\": \"auto\",\"alter_id\": 0,\"transport\": {\"type\": \"httpupgrade\",\"path\": \"$ph\"},\"tls\": {\"enabled\": true,\"server_name\": \"$dm\",\"utls\": {\"enabled\": true,\"fingerprint\": \"chrome\"}}}"
            ;;
        7)
            si="{\"type\": \"trojan\",\"listen\": \"::\",\"listen_port\": $pt,\"users\": [{\"password\": \"$ud\"}],\"tls\": {\"enabled\": true,\"server_name\": \"$dm\",\"certificate_path\": \"${CR}/fullchain.cer\",\"key_path\": \"${CR}/private.key\"}}"
            co="{\"type\": \"trojan\",\"tag\": \"proxy\",\"server\": \"$dm\",\"server_port\": $pt,\"password\": \"$ud\",\"tls\": {\"enabled\": true,\"server_name\": \"$dm\",\"utls\": {\"enabled\": true,\"fingerprint\": \"chrome\"}}}"
            ;;
        8)
            si="{\"type\": \"hysteria2\",\"listen\": \"::\",\"listen_port\": $pt,\"users\": [{\"password\": \"$ud\"}],\"tls\": {\"enabled\": true,\"server_name\": \"$dm\",\"alpn\": [\"h3\"],\"certificate_path\": \"${CR}/fullchain.cer\",\"key_path\": \"${CR}/private.key\"}}"
            co="{\"type\": \"hysteria2\",\"tag\": \"proxy\",\"server\": \"$dm\",\"server_port\": $pt,\"password\": \"$ud\",\"tls\": {\"enabled\": true,\"server_name\": \"$dm\",\"alpn\": [\"h3\"],\"utls\": {\"enabled\": true,\"fingerprint\": \"chrome\"}}}"
            ;;
        9)
            si="{\"type\": \"tuic\",\"listen\": \"::\",\"listen_port\": $pt,\"users\": [{\"uuid\": \"$ud\", \"password\": \"$ud\"}],\"congestion_control\": \"bbr\",\"tls\": {\"enabled\": true,\"server_name\": \"$dm\",\"alpn\": [\"h3\"],\"certificate_path\": \"${CR}/fullchain.cer\",\"key_path\": \"${CR}/private.key\"}}"
            co="{\"type\": \"tuic\",\"tag\": \"proxy\",\"server\": \"$dm\",\"server_port\": $pt,\"uuid\": \"$ud\",\"password\": \"$ud\",\"congestion_control\": \"bbr\",\"tls\": {\"enabled\": true,\"server_name\": \"$dm\",\"alpn\": [\"h3\"],\"utls\": {\"enabled\": true,\"fingerprint\": \"chrome\"}}}"
            ;;
        10)
            si="{\"type\": \"socks\",\"listen\": \"::\",\"listen_port\": $pt,\"users\": [{\"username\": \"$ud\", \"password\": \"$ud\"}]}"
            co="{\"type\": \"socks\",\"tag\": \"proxy\",\"server\": \"$ip\",\"server_port\": $pt,\"username\": \"$ud\",\"password\": \"$ud\"}"
            ;;
        *) echo -e "${R}错误${P}"; exit 1 ;;
    esac

    echo "{\"log\": {\"level\": \"info\"},\"inbounds\": [$si]}" > "$CS"

    cat <<EOF > /etc/systemd/system/sing-box.service
[Unit]
After=network.target
[Service]
ExecStart=$BP run -c $CS
Restart=always
User=root
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl restart sing-box && systemctl enable sing-box
    echo -e "\n${G}服务端配置完毕${P}"
    echo -e "${B}=== 节点JSON (请复制并导入客户端) ===${P}"
    echo "$co" | jq .
    echo -e "${B}=====================================${P}"
}

inn() {
    mkdir -p "$ND"
    read -r -p "节点别名 (如 us1): " na
    [[ -z "$na" ]] && { echo -e "${R}别名不可为空${P}"; return; }
    echo -e "${B}粘贴JSON配置 (回车后按 Ctrl+D 结束):${P}"
    cat | jq . > "$ND/$na.json"
    echo -e "${G}导入成功: $na${P}"
}

lsn() {
    mkdir -p "$ND"
    echo -e "${B}--- 节点列表 ---${P}"
    for f in "$ND"/*.json; do
        [[ -f "$f" ]] || continue
        local na=$(basename "$f" .json)
        local sv=$(jq -r .server "$f" 2>/dev/null)
        local la=$(ping -c 1 -W 1 "$sv" 2>/dev/null | grep time= | awk -F'time=' '{print $2}')
        [[ -z "$la" ]] && la="超时"
        echo -e "${G}$na${P} -> $sv (延迟: $la)"
    done
}

rmn() {
    mkdir -p "$ND"
    ls -1 "$ND" | sed 's/\.json$//'
    read -r -p "输入要删除的别名: " na
    if [[ -f "$ND/$na.json" ]]; then
        rm -f "$ND/$na.json"
        echo -e "${G}已删除 $na${P}"
    else
        echo -e "${R}节点不存在${P}"
    fi
}

tgc() {
    if [[ "$1" == "start" ]]; then
        mkdir -p "$ND"
        echo -e "${B}可用节点:${P}"
        ls -1 "$ND" | sed 's/\.json$//'
        read -r -p "输入需要启用的节点别名: " na
        if [[ -f "$ND/$na.json" ]]; then
            local nj=$(cat "$ND/$na.json")
            cat <<EOF > "$CC"
{"log": {"level": "info"},"inbounds": [{"type": "tun","tag": "tun-in","interface_name": "sing-tun","inet4_address": "172.19.0.1/30","auto_route": true,"strict_route": true,"sniff": true},{"type":"mixed","tag":"mix-in","listen":"127.0.0.1","listen_port":2080}],"outbounds": [$nj,{"type": "direct", "tag": "direct"},{"type": "block", "tag": "block"}],"route": {"rules": [{"protocol": "ssh","outbound": "direct"},{"port": 22,"outbound": "direct"},{"geosite": ["cn"], "geoip": ["cn", "private"], "outbound": "direct"}],"auto_detect_interface": true}}
EOF
            cat <<EOF > /etc/systemd/system/sing-box-client.service
[Unit]
After=network.target
[Service]
ExecStart=$BP run -c $CC
Restart=on-failure
User=root
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload
            systemctl start sing-box-client && systemctl enable sing-box-client
            echo -e "${G}全局透明代理已启动 ($na)${P}"
        else
            echo -e "${R}节点不存在${P}"
        fi
    elif [[ "$1" == "stop" ]]; then
        systemctl stop sing-box-client && systemctl disable sing-box-client
        echo -e "${Y}已断开，物理直连恢复${P}"
    fi
}

sc() {
    echo -e "${B}=====================================${P}"
    echo "1. 导入新节点"
    echo "2. 节点测速列表"
    echo "3. 选择节点并开启代理"
    echo "4. 关闭代理"
    echo "5. 删除节点"
    echo "0. 返回"
    echo -e "${B}=====================================${P}"
    read -r cc
    case "$cc" in
        1) inn ;;
        2) lsn ;;
        3) tgc start ;;
        4) tgc stop ;;
        5) rmn ;;
        0) m ;;
        *) echo -e "${R}错误${P}" ;;
    esac
}

st() {
    echo -e "\n${B}--- 内核版本检查 ---${P}"
    if [[ -f "$BP" ]]; then
        local cv=$($BP version | grep "sing-box version" | awk '{print $3}')
        local nv=$(curl -s -m 5 https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name)
        local nt=${nv#v}
        if [[ "$cv" == "$nt" ]]; then
            echo -e "${G}已是最新版 ($cv)${P}"
        else
            echo -e "${Y}发现新版本 ($nv)，正在平滑更新...${P}"
            ins
            systemctl is-active --quiet sing-box && systemctl restart sing-box
            systemctl is-active --quiet sing-box-client && systemctl restart sing-box-client
            echo -e "${G}更新完毕${P}"
        fi
    else
        echo -e "${R}内核未安装${P}"
    fi

    echo -e "\n${B}--- 本机 IP (直连) ---${P}"
    local i4=$(curl -s4 -m 3 ip.sb)
    local i6=$(curl -s6 -m 3 ip.sb)
    local go=$(curl -s -m 3 ipinfo.io/country)
    [[ -n "$i4" ]] && echo -e "IPv4: ${G}$i4${P} ($go)" || echo -e "IPv4: ${R}无${P}"
    [[ -n "$i6" ]] && echo -e "IPv6: ${G}$i6${P}" || echo -e "IPv6: ${R}无${P}"

    if systemctl is-active --quiet sing-box-client; then
        echo -e "\n${B}--- 节点 IP (代理) ---${P}"
        local pi4=$(curl -x socks5h://127.0.0.1:2080 -s4 -m 5 ip.sb)
        local pi6=$(curl -x socks5h://127.0.0.1:2080 -s6 -m 5 ip.sb)
        local pgo=$(curl -x socks5h://127.0.0.1:2080 -s -m 5 ipinfo.io/country)
        [[ -n "$pi4" ]] && echo -e "IPv4: ${G}$pi4${P} ($pgo)" || echo -e "IPv4: ${R}无${P}"
        [[ -n "$pi6" ]] && echo -e "IPv6: ${G}$pi6${P}" || echo -e "IPv6: ${R}无${P}"
    fi

    echo -e "\n${B}--- 证书续签状态 ---${P}"
    if [[ -f "${CR}/domain.txt" ]]; then
        local d=$(cat "${CR}/domain.txt")
        echo -e "域名: ${G}$d${P}"
        if [[ -f "${CR}/fullchain.cer" ]]; then
            local ed=$(openssl x509 -in ${CR}/fullchain.cer -noout -enddate 2>/dev/null | cut -d= -f2)
            echo -e "到期时间: ${G}$ed${P}"
        fi
        if crontab -l | grep -q "RenewTLS"; then
            echo -e "自动续签: ${G}已开启${P}"
        else
            echo -e "自动续签: ${R}未开启${P}"
        fi
    else
        echo -e "${Y}无需证书或未配置${P}"
    fi
    echo ""
}

ua() {
    echo -e "${R}确认彻底卸载？[y/n]: ${P}"
    read -r cf
    if [[ "$cf" != "y" ]]; then return; fi
    systemctl stop sing-box sing-box-client >/dev/null 2>&1
    systemctl disable sing-box sing-box-client >/dev/null 2>&1
    rm -f /etc/systemd/system/sing-box.service /etc/systemd/system/sing-box-client.service
    systemctl daemon-reload
    if [[ -f "$HOME/.acme.sh/acme.sh" ]]; then
        "$HOME/.acme.sh/acme.sh" --uninstall
        rm -rf "$HOME/.acme.sh"
    fi
    crontab -l > /tmp/bc.cron 2>/dev/null
    sed -i '/s.sh RenewTLS/d' /tmp/bc.cron
    crontab /tmp/bc.cron
    rm -rf "$BP" "$CD" /usr/bin/s /root/s.sh
    echo -e "${G}卸载完成，系统无残留${P}"
    exit 0
}

m() {
    clear
    echo -e "${B}=====================================${P}"
    echo -e "${G}   Sing-box 管理面板${P}"
    echo -e "${B}=====================================${P}"
    echo "1. 服务端配置"
    echo "2. 客户端节点"
    echo "3. 系统状态"
    echo "4. 彻底卸载"
    echo "0. 退出"
    echo -e "${B}=====================================${P}"
    read -r -p "选择: " ch
    case "$ch" in
        1) ss ;;
        2) sc ;;
        3) st ;;
        4) ua ;;
        0) exit 0 ;;
        *) echo -e "${R}错误${P}"; sleep 1; m ;;
    esac
}

m
