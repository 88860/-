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

pause() {
    read -n1 -r -p "按任意键继续..."
    echo ""
}

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
            echo -e "${Y}安装依赖: $d ${P}"
            if command -v apt >/dev/null 2>&1; then
                apt update >/dev/null 2>&1 && apt install -y "$d" >/dev/null 2>&1
            elif command -v yum >/dev/null 2>&1; then
                yum install -y "$d" >/dev/null 2>&1
            fi
        fi
    done
    if ! command -v dig >/dev/null 2>&1; then
        if command -v apt >/dev/null 2>&1; then apt install -y dnsutils >/dev/null 2>&1; fi
        if command -v yum >/dev/null 2>&1; then yum install -y bind-utils >/dev/null 2>&1; fi
    fi
}

dc() {
    local a=$(uname -m)
    if [[ "$a" == "x86_64" || "$a" == "amd64" ]]; then
        if grep -q "avx2" /proc/cpuinfo; then echo "amd64v3"; else echo "amd64"; fi
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
    local u="https://github.com/SagerNet/sing-box/releases/download/${v}/sing-box-${v#v}-linux-${c}.tar.gz"
    
    wget -qO /tmp/sb.tar.gz "$u" || wget -qO /tmp/sb.tar.gz "https://ghp.ci/$u"
    
    if ! tar -xzf /tmp/sb.tar.gz -C /tmp 2>/dev/null; then
        echo -e "${R}解压失败: 下载无效，请检查网络是否能访问 GitHub。${P}"
        rm -f /tmp/sb.tar.gz
        exit 1
    fi
    
    mkdir -p "$CD" "$CR" "$ND"
    mv /tmp/sing-box-*/sing-box "$BP"
    chmod +x "$BP"
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
    clear
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
    echo "0. 返回"
    echo -e "${B}=====================================${P}"
    read -r -p "选择: " pc
    
    if [[ "$pc" == "0" ]]; then return; fi
    if [[ ! "$pc" =~ ^([1-9]|10)$ ]]; then echo -e "${R}选错${P}"; sleep 1; ss; return; fi

    local dm=""
    if [[ "$pc" =~ ^[3-9]$ ]]; then
        read -r -p "解析到本机的域名: " dm
        if [[ -z "$dm" ]]; then echo -e "${R}域名不可为空${P}"; sleep 1; ss; return; fi
    fi

    if [[ ! -f "$BP" ]]; then ins; fi
    mkdir -p "$CD" "$CR" "$ND"
    if [[ "$pc" =~ ^[3-9]$ ]]; then ic "$dm"; fi

    local pt=$((RANDOM % 20000 + 10000))
    local ud=$($BP generate uuid)
    local ip=$(curl -s4 -m 5 ip.sb)
    local co=""
    local si=""

    op $pt tcp
    op $pt udp

    case "$pc" in
        1)
            local ks=$($BP generate reality-keypair)
            local pk=$(echo "$ks" | grep PrivateKey | awk '{print $2}'); local pb=$(echo "$ks" | grep PublicKey | awk '{print $2}')
            si="{\"type\": \"vless\",\"listen\": \"::\",\"listen_port\": $pt,\"users\": [{\"uuid\": \"$ud\",\"flow\": \"xtls-rprx-vision\"}],\"tls\": {\"enabled\": true,\"server_name\": \"www.microsoft.com\",\"reality\": {\"enabled\": true,\"handshake\": {\"server\": \"www.microsoft.com\",\"server_port\": 443},\"private_key\": \"$pk\",\"short_id\": [\"\",\"6ba85179e30d4fc2\"]}}}"
            co="vless://${ud}@${ip}:${pt}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=chrome&pbk=${pb}&sid=6ba85179e30d4fc2&type=tcp&headerType=none#VLESS-Reality"
            ;;
        2)
            local ks=$($BP generate reality-keypair)
            local pk=$(echo "$ks" | grep PrivateKey | awk '{print $2}'); local pb=$(echo "$ks" | grep PublicKey | awk '{print $2}')
            si="{\"type\": \"vless\",\"listen\": \"::\",\"listen_port\": $pt,\"users\": [{\"uuid\": \"$ud\"}],\"transport\": {\"type\": \"grpc\",\"service_name\": \"grpc\"},\"tls\": {\"enabled\": true,\"server_name\": \"www.microsoft.com\",\"reality\": {\"enabled\": true,\"handshake\": {\"server\": \"www.microsoft.com\",\"server_port\": 443},\"private_key\": \"$pk\",\"short_id\": [\"\",\"6ba85179e30d4fc2\"]}}}"
            co="vless://${ud}@${ip}:${pt}?encryption=none&security=reality&sni=www.microsoft.com&fp=chrome&pbk=${pb}&sid=6ba85179e30d4fc2&type=grpc&serviceName=grpc#VLESS-gRPC"
            ;;
        3)
            si="{\"type\": \"vless\",\"listen\": \"::\",\"listen_port\": $pt,\"users\": [{\"uuid\": \"$ud\",\"flow\": \"xtls-rprx-vision\"}],\"tls\": {\"enabled\": true,\"server_name\": \"$dm\",\"certificate_path\": \"${CR}/fullchain.cer\",\"key_path\": \"${CR}/private.key\"}}"
            co="vless://${ud}@${dm}:${pt}?encryption=none&flow=xtls-rprx-vision&security=tls&sni=${dm}&fp=chrome&type=tcp&headerType=none#VLESS-Vision"
            ;;
        4)
            local ph="/$(tr -dc 'a-z0-9' </dev/urandom | head -c 6)ws"
            si="{\"type\": \"vless\",\"listen\": \"::\",\"listen_port\": $pt,\"users\": [{\"uuid\": \"$ud\"}],\"transport\": {\"type\": \"ws\",\"path\": \"$ph\"},\"tls\": {\"enabled\": true,\"server_name\": \"$dm\",\"certificate_path\": \"${CR}/fullchain.cer\",\"key_path\": \"${CR}/private.key\"}}"
            co="vless://${ud}@${dm}:${pt}?encryption=none&security=tls&sni=${dm}&fp=chrome&type=ws&path=${ph}#VLESS-WS"
            ;;
        5)
            local ph="/$(tr -dc 'a-z0-9' </dev/urandom | head -c 6)vws"
            si="{\"type\": \"vmess\",\"listen\": \"::\",\"listen_port\": $pt,\"users\": [{\"uuid\": \"$ud\",\"alterId\": 0}],\"transport\": {\"type\": \"ws\",\"path\": \"$ph\"},\"tls\": {\"enabled\": true,\"server_name\": \"$dm\",\"certificate_path\": \"${CR}/fullchain.cer\",\"key_path\": \"${CR}/private.key\"}}"
            local vj="{\"v\":\"2\",\"ps\":\"VMess-WS\",\"add\":\"${dm}\",\"port\":${pt},\"id\":\"${ud}\",\"aid\":\"0\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"${dm}\",\"path\":\"${ph}\",\"tls\":\"tls\",\"sni\":\"${dm}\"}"
            co="vmess://$(echo -n "$vj" | base64 -w 0)"
            ;;
        6)
            local ph="/$(tr -dc 'a-z0-9' </dev/urandom | head -c 6)hup"
            si="{\"type\": \"vmess\",\"listen\": \"::\",\"listen_port\": $pt,\"users\": [{\"uuid\": \"$ud\",\"alterId\": 0}],\"transport\": {\"type\": \"httpupgrade\",\"path\": \"$ph\"},\"tls\": {\"enabled\": true,\"server_name\": \"$dm\",\"certificate_path\": \"${CR}/fullchain.cer\",\"key_path\": \"${CR}/private.key\"}}"
            local vj="{\"v\":\"2\",\"ps\":\"VMess-HTTPUpgrade\",\"add\":\"${dm}\",\"port\":${pt},\"id\":\"${ud}\",\"aid\":\"0\",\"net\":\"httpupgrade\",\"type\":\"none\",\"host\":\"${dm}\",\"path\":\"${ph}\",\"tls\":\"tls\",\"sni\":\"${dm}\"}"
            co="vmess://$(echo -n "$vj" | base64 -w 0)"
            ;;
        7)
            si="{\"type\": \"trojan\",\"listen\": \"::\",\"listen_port\": $pt,\"users\": [{\"password\": \"$ud\"}],\"tls\": {\"enabled\": true,\"server_name\": \"$dm\",\"certificate_path\": \"${CR}/fullchain.cer\",\"key_path\": \"${CR}/private.key\"}}"
            co="trojan://${ud}@${dm}:${pt}?security=tls&sni=${dm}&fp=chrome&type=tcp#Trojan"
            ;;
        8)
            si="{\"type\": \"hysteria2\",\"listen\": \"::\",\"listen_port\": $pt,\"users\": [{\"password\": \"$ud\"}],\"tls\": {\"enabled\": true,\"server_name\": \"$dm\",\"alpn\": [\"h3\"],\"certificate_path\": \"${CR}/fullchain.cer\",\"key_path\": \"${CR}/private.key\"}}"
            co="hysteria2://${ud}@${dm}:${pt}?peer=${dm}&insecure=0&sni=${dm}&alpn=h3#Hysteria2"
            ;;
        9)
            si="{\"type\": \"tuic\",\"listen\": \"::\",\"listen_port\": $pt,\"users\": [{\"uuid\": \"$ud\", \"password\": \"$ud\"}],\"congestion_control\": \"bbr\",\"tls\": {\"enabled\": true,\"server_name\": \"$dm\",\"alpn\": [\"h3\"],\"certificate_path\": \"${CR}/fullchain.cer\",\"key_path\": \"${CR}/private.key\"}}"
            co="tuic://${ud}:${ud}@${dm}:${pt}?congestion_control=bbr&sni=${dm}&alpn=h3#TUIC"
            ;;
        10)
            si="{\"type\": \"socks\",\"listen\": \"::\",\"listen_port\": $pt,\"users\": [{\"username\": \"$ud\", \"password\": \"$ud\"}]}"
            co="socks5://${ud}:${ud}@${ip}:${pt}#SOCKS5"
            ;;
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
    echo -e "${B}=== 分享链接 (请复制并导入客户端) ===${P}"
    echo "$co"
    echo -e "${B}=====================================${P}"
    pause
}

u2j() {
    local u="$1"
    local pr=$(echo "$u" | awk -F'://' '{print $1}')
    local ma=$(echo "$u" | awk -F'://' '{print $2}' | awk -F'#' '{print $1}')
    local qu=$(echo "$ma" | awk -F'?' '{print $2}')
    local au=$(echo "$ma" | awk -F'?' '{print $1}')
    local ui=$(echo "$au" | grep -o '.*@' | sed 's/@$//')
    local hp=$(echo "$au" | sed "s/^$ui@//")
    local ho=$(echo "$hp" | awk -F':' '{print $1}')
    local po=$(echo "$hp" | awk -F':' '{print $2}')
    
    gq() { echo "$1" | tr '&' '\n' | grep "^$2=" | cut -d= -f2- ; }

    if [[ "$pr" == "hysteria2" ]]; then
        local sn=$(gq "$qu" "sni")
        local al=$(gq "$qu" "alpn"); [[ -z "$al" ]] && al="h3"
        echo "{\"type\":\"hysteria2\",\"tag\":\"proxy\",\"server\":\"$ho\",\"server_port\":$po,\"password\":\"$ui\",\"tls\":{\"enabled\":true,\"server_name\":\"$sn\",\"alpn\":[\"$al\"],\"utls\":{\"enabled\":true,\"fingerprint\":\"chrome\"}}}"
    elif [[ "$pr" == "socks5" ]]; then
        local us=$(echo "$ui" | cut -d: -f1)
        local pa=$(echo "$ui" | cut -d: -f2)
        echo "{\"type\":\"socks\",\"tag\":\"proxy\",\"server\":\"$ho\",\"server_port\":$po,\"username\":\"$us\",\"password\":\"$pa\"}"
    elif [[ "$pr" == "tuic" ]]; then
        local uu=$(echo "$ui" | cut -d: -f1)
        local pa=$(echo "$ui" | cut -d: -f2)
        local sn=$(gq "$qu" "sni")
        local cc=$(gq "$qu" "congestion_control")
        local al=$(gq "$qu" "alpn")
        echo "{\"type\":\"tuic\",\"tag\":\"proxy\",\"server\":\"$ho\",\"server_port\":$po,\"uuid\":\"$uu\",\"password\":\"$pa\",\"congestion_control\":\"$cc\",\"tls\":{\"enabled\":true,\"server_name\":\"$sn\",\"alpn\":[\"$al\"],\"utls\":{\"enabled\":true,\"fingerprint\":\"chrome\"}}}"
    elif [[ "$pr" == "vless" || "$pr" == "trojan" ]]; then
        local sn=$(gq "$qu" "sni")
        local tp=$(gq "$qu" "type")
        local sc=$(gq "$qu" "security")
        local tl="\"tls\":{\"enabled\":true,\"server_name\":\"$sn\",\"utls\":{\"enabled\":true,\"fingerprint\":\"chrome\"}"
        if [[ "$sc" == "reality" ]]; then
            local pb=$(gq "$qu" "pbk")
            local sd=$(gq "$qu" "sid")
            tl="$tl,\"reality\":{\"enabled\":true,\"public_key\":\"$pb\",\"short_id\":\"$sd\"}}"
        else
            tl="$tl}"
        fi
        local tr=""
        if [[ "$tp" == "ws" ]]; then tr=",\"transport\":{\"type\":\"ws\",\"path\":\"$(gq "$qu" "path")\"}"; fi
        if [[ "$tp" == "grpc" ]]; then tr=",\"transport\":{\"type\":\"grpc\",\"service_name\":\"$(gq "$qu" "serviceName")\"}"; fi
        
        if [[ "$pr" == "vless" ]]; then
            local fw=$(gq "$qu" "flow")
            [[ -n "$fw" ]] && fw=",\"flow\":\"$fw\""
            echo "{\"type\":\"vless\",\"tag\":\"proxy\",\"server\":\"$ho\",\"server_port\":$po,\"uuid\":\"$ui\"${fw},${tl}${tr}}"
        else
            echo "{\"type\":\"trojan\",\"tag\":\"proxy\",\"server\":\"$ho\",\"server_port\":$po,\"password\":\"$ui\",${tl}${tr}}"
        fi
    elif [[ "$pr" == "vmess" ]]; then
        local vj=$(echo "$u" | sed 's/vmess:\/\///' | base64 -d 2>/dev/null)
        local va=$(echo "$vj" | jq -r .add)
        local vp=$(echo "$vj" | jq -r .port)
        local vi=$(echo "$vj" | jq -r .id)
        local vn=$(echo "$vj" | jq -r .net)
        local vs=$(echo "$vj" | jq -r .sni)
        local vph=$(echo "$vj" | jq -r .path)
        echo "{\"type\":\"vmess\",\"tag\":\"proxy\",\"server\":\"$va\",\"server_port\":$vp,\"uuid\":\"$vi\",\"security\":\"auto\",\"alter_id\":0,\"tls\":{\"enabled\":true,\"server_name\":\"$vs\",\"utls\":{\"enabled\":true,\"fingerprint\":\"chrome\"}},\"transport\":{\"type\":\"$vn\",\"path\":\"$vph\"}}"
    fi
}

in_c() {
    mkdir -p "$ND"
    read -r -p "请输入节点保存名称 (如 us1): " na
    [[ -z "$na" ]] && { echo -e "${R}名称不可为空${P}"; pause; return; }
    
    read -r -p "粘贴节点链接 (如 hysteria2://...): " uri
    [[ -z "$uri" ]] && { echo -e "${R}链接不可为空${P}"; pause; return; }

    if [[ "$uri" == vmess://* ]]; then
        local vj=$(echo "$uri" | sed 's/vmess:\/\///' | base64 -d 2>/dev/null)
        vj=$(echo "$vj" | jq -c ".ps=\"$na\"")
        uri="vmess://$(echo -n "$vj" | base64 -w 0)"
    else
        uri=$(echo "$uri" | awk -F'#' '{print $1}')
        uri="${uri}#${na}"
    fi

    echo "$uri" > "$ND/$na.uri"
    echo -e "${G}成功识别并保存节点: $na${P}"
    pause
}

ls_c() {
    mkdir -p "$ND"
    local fs=("$ND"/*.uri)
    if [[ ${#fs[@]} -eq 0 || ! -f "${fs[0]}" ]]; then
        echo -e "${Y}暂无保存的节点，请先导入新节点${P}"; pause; return
    fi

    echo -e "${B}--- 节点列表 ---${P}"
    for i in "${!fs[@]}"; do
        local na=$(basename "${fs[$i]}" .uri)
        local ur=$(cat "${fs[$i]}")
        local pr=$(echo "$ur" | awk -F'://' '{print $1}')
        echo "$((i+1)). $na [$pr]"
    done
    echo "0. 返回"
    echo -e "${B}----------------${P}"
    read -r -p "输入数字选择节点并启用: " sel
    
    if [[ "$sel" == "0" ]]; then return; fi
    if [[ ! "$sel" =~ ^[0-9]+$ ]] || [ "$sel" -lt 1 ] || [ "$sel" -gt "${#fs[@]}" ]; then
        echo -e "${R}选错${P}"; sleep 1; ls_c; return
    fi

    local f="${fs[$((sel-1))]}"
    local ur=$(cat "$f")
    local na=$(basename "$f" .uri)
    
    local nj=$(u2j "$ur")
    if [[ -z "$nj" ]]; then echo -e "${R}解析 JSON 失败${P}"; pause; return; fi

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
    systemctl restart sing-box-client && systemctl enable sing-box-client
    echo -e "${G}全局透明代理已启动 ($na)${P}"
    echo -e "${B}正在检测网络连通性...${P}"
    sleep 2
    
    local i4=$(curl -x socks5h://127.0.0.1:2080 -s4 -m 5 ip.sb 2>/dev/null)
    local i6=$(curl -x socks5h://127.0.0.1:2080 -s6 -m 5 ip.sb 2>/dev/null)
    local go=$(curl -x socks5h://127.0.0.1:2080 -s -m 5 ipinfo.io/country 2>/dev/null)
    [[ -n "$i4" ]] && echo -e "IPv4: ${G}$i4${P} (国家: $go)" || echo -e "IPv4: ${R}无${P}"
    [[ -n "$i6" ]] && echo -e "IPv6: ${G}$i6${P}" || echo -e "IPv6: ${R}无${P}"
    
    local lat=$(curl -o /dev/null -s -w "%{time_total}\n" -m 5 -x socks5h://127.0.0.1:2080 https://www.google.com 2>/dev/null)
    if [[ -n "$lat" && "$lat" != "0.000" ]]; then
        echo -e "TCP: ${G}连通${P} (Google 延迟: ${lat}秒)"
    else
        echo -e "TCP: ${R}失败或超时${P}"
    fi

    if dig @8.8.8.8 google.com +time=3 +short >/dev/null 2>&1; then
        echo -e "UDP: ${G}连通${P} (DNS解析成功)"
    else
        echo -e "UDP: ${Y}未知或失败${P}"
    fi
    pause
}

ex_c() {
    mkdir -p "$ND"
    local fs=("$ND"/*.uri)
    if [[ ${#fs[@]} -eq 0 || ! -f "${fs[0]}" ]]; then
        echo -e "${Y}暂无保存的节点${P}"; pause; return
    fi
    echo -e "${B}--- 导出节点 ---${P}"
    for i in "${!fs[@]}"; do
        local na=$(basename "${fs[$i]}" .uri)
        echo "$((i+1)). $na"
    done
    echo "0. 返回"
    echo -e "${B}----------------${P}"
    read -r -p "输入数字导出: " sel
    if [[ "$sel" == "0" ]]; then return; fi
    if [[ ! "$sel" =~ ^[0-9]+$ ]] || [ "$sel" -lt 1 ] || [ "$sel" -gt "${#fs[@]}" ]; then
        echo -e "${R}选错${P}"; sleep 1; ex_c; return
    fi
    local f="${fs[$((sel-1))]}"
    echo -e "\n${G}节点链接:${P}"
    cat "$f"
    echo ""
    pause
}

rm_c() {
    mkdir -p "$ND"
    local fs=("$ND"/*.uri)
    if [[ ${#fs[@]} -eq 0 || ! -f "${fs[0]}" ]]; then
        echo -e "${Y}暂无保存的节点${P}"; pause; return
    fi
    echo -e "${B}--- 删除节点 ---${P}"
    for i in "${!fs[@]}"; do
        local na=$(basename "${fs[$i]}" .uri)
        echo "$((i+1)). $na"
    done
    echo "0. 返回"
    echo -e "${B}----------------${P}"
    read -r -p "输入数字删除: " sel
    if [[ "$sel" == "0" ]]; then return; fi
    if [[ ! "$sel" =~ ^[0-9]+$ ]] || [ "$sel" -lt 1 ] || [ "$sel" -gt "${#fs[@]}" ]; then
        echo -e "${R}选择无效${P}"; sleep 1; rm_c; return
    fi
    local f="${fs[$((sel-1))]}"
    local na=$(basename "$f" .uri)
    rm -f "$f"
    echo -e "${G}已删除: $na${P}"
    pause
