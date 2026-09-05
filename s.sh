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
LK="${CD}/server_links.txt"

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
    local ipt_p="${p//-/:}"
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q active; then
        ufw allow "$p/$c" >/dev/null 2>&1
    elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --add-port="$p/$c" >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
    else
        if command -v nft >/dev/null 2>&1; then
            nft add rule inet filter input $c dport "$ipt_p" accept >/dev/null 2>&1 || \
            nft add rule ip filter INPUT $c dport "$ipt_p" accept >/dev/null 2>&1
        fi
        if command -v iptables >/dev/null 2>&1; then
            iptables -I INPUT -p "$c" --dport "$ipt_p" -j ACCEPT >/dev/null 2>&1
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

u2j() {
    local uri="$1"
    local proto=$(echo "$uri" | awk -F'://' '{print $1}')
    local rest=$(echo "$uri" | awk -F'://' '{print $2}' | awk -F'#' '{print $1}')
    
    if [[ "$proto" == "vmess" ]]; then
        local b64=$(echo "$rest" | tr '_-' '/+')
        local vj=$(echo "$b64" | base64 -d 2>/dev/null)
        local add=$(echo "$vj" | jq -r .add)
        local port=$(echo "$vj" | jq -r .port)
        local id=$(echo "$vj" | jq -r .id)
        local net=$(echo "$vj" | jq -r .net)
        local sni=$(echo "$vj" | jq -r .sni)
        local path=$(echo "$vj" | jq -r .path)
        echo "{\"type\":\"vmess\",\"tag\":\"proxy\",\"server\":\"$add\",\"server_port\":$port,\"uuid\":\"$id\",\"security\":\"auto\",\"alter_id\":0,\"tls\":{\"enabled\":true,\"server_name\":\"$sni\",\"utls\":{\"enabled\":true,\"fingerprint\":\"chrome\"}},\"transport\":{\"type\":\"$net\",\"path\":\"$path\"}}"
        return
    fi

    local user_pass=$(echo "$rest" | grep -o '.*@' | sed 's/@$//')
    local host_port_params=$(echo "$rest" | sed "s/^${user_pass}@//")
    local host_port=$(echo "$host_port_params" | awk -F'?' '{print $1}')
    local params=$(echo "$host_port_params" | awk -F'?' '{print $2}')
    
    local host=$(echo "$host_port" | awk -F':' '{print $1}')
    local port=$(echo "$host_port" | awk -F':' '{print $2}')

    get_param() { 
        echo "$params" | tr '&' '\n' | grep "^$1=" | cut -d= -f2- | sed 's/%([0-9A-Fa-f]{2})/\\x\1/g' | xargs -I {} printf "%b" "{}" 2>/dev/null || echo ""
    }

    local res=""
    if [[ "$proto" == "socks5" ]]; then
        local user=$(echo "$user_pass" | cut -d: -f1)
        local pass=$(echo "$user_pass" | cut -d: -f2)
        res="{\"type\":\"socks\",\"tag\":\"proxy\",\"server\":\"$host\",\"server_port\":$port,\"username\":\"$user\",\"password\":\"$pass\"}"
    elif [[ "$proto" == "tuic" ]]; then
        local uuid=$(echo "$user_pass" | cut -d: -f1)
        local pass=$(echo "$user_pass" | cut -d: -f2)
        local sni=$(get_param "sni")
        local alpn=$(get_param "alpn"); [[ -z "$alpn" ]] && alpn="h3"
        local cc=$(get_param "congestion_control"); [[ -z "$cc" ]] && cc="bbr"
        res="{\"type\":\"tuic\",\"tag\":\"proxy\",\"server\":\"$host\",\"server_port\":$port,\"uuid\":\"$uuid\",\"password\":\"$pass\",\"congestion_control\":\"$cc\",\"tls\":{\"enabled\":true,\"server_name\":\"$sni\",\"alpn\":[\"$alpn\"],\"utls\":{\"enabled\":true,\"fingerprint\":\"chrome\"}}}"
    elif [[ "$proto" == "hysteria2" ]]; then
        local pass="$user_pass"
        local sni=$(get_param "sni")
        local alpn=$(get_param "alpn"); [[ -z "$alpn" ]] && alpn="h3"
        local insecure=$(get_param "insecure")
        local ins_val="false"
        [[ "$insecure" == "1" || "$insecure" == "true" ]] && ins_val="true"
        res="{\"type\":\"hysteria2\",\"tag\":\"proxy\",\"server\":\"$host\",\"server_port\":$port,\"password\":\"$pass\",\"tls\":{\"enabled\":true,\"server_name\":\"$sni\",\"insecure\":$ins_val,\"alpn\":[\"$alpn\"],\"utls\":{\"enabled\":true,\"fingerprint\":\"chrome\"}}}"
    elif [[ "$proto" == "trojan" ]]; then
        local pass="$user_pass"
        local sni=$(get_param "sni")
        res="{\"type\":\"trojan\",\"tag\":\"proxy\",\"server\":\"$host\",\"server_port\":$port,\"password\":\"$pass\",\"tls\":{\"enabled\":true,\"server_name\":\"$sni\",\"utls\":{\"enabled\":true,\"fingerprint\":\"chrome\"}}}"
    elif [[ "$proto" == "vless" ]]; then
        local uuid="$user_pass"
        local sni=$(get_param "sni")
        local flow=$(get_param "flow")
        local sec=$(get_param "security")
        local type=$(get_param "type")
        
        local tls_obj="\"tls\":{\"enabled\":true,\"server_name\":\"$sni\",\"utls\":{\"enabled\":true,\"fingerprint\":\"chrome\"}"
        if [[ "$sec" == "reality" ]]; then
            local pbk=$(get_param "pbk")
            local sid=$(get_param "sid")
            tls_obj="${tls_obj},\"reality\":{\"enabled\":true,\"public_key\":\"$pbk\",\"short_id\":\"$sid\"}}"
        else
            tls_obj="${tls_obj}}"
        fi
        
        local trans_obj=""
        if [[ "$type" == "ws" ]]; then trans_obj=",\"transport\":{\"type\":\"ws\",\"path\":\"$(get_param "path")\"}"; fi
        if [[ "$type" == "grpc" ]]; then trans_obj=",\"transport\":{\"type\":\"grpc\",\"service_name\":\"$(get_param "serviceName")\"}"; fi
        
        local flow_str=""
        [[ -n "$flow" ]] && flow_str=",\"flow\":\"$flow\""
        
        res="{\"type\":\"vless\",\"tag\":\"proxy\",\"server\":\"$host\",\"server_port\":$port,\"uuid\":\"$uuid\"${flow_str},${tls_obj}${trans_obj}}"
    fi
    
    if echo "$res" | jq empty 2>/dev/null; then
        echo "$res"
    else
        echo ""
    fi
}

ss() {
    while true; do
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
        if [[ ! "$pc" =~ ^([1-9]|10)$ ]]; then echo -e "${R}选错${P}"; sleep 1; continue; fi

        local dm=""
        if [[ "$pc" =~ ^[3-9]$ ]]; then
            read -r -p "请输入解析到本机的域名: " dm
            if [[ -z "$dm" ]]; then echo -e "${R}域名不可为空${P}"; pause; continue; fi
        fi

        local default_pt=$((RANDOM % 20000 + 10000))
        read -r -p "请输入端口 (回车默认随机 $default_pt): " pt
        [[ -z "$pt" ]] && pt="$default_pt"

        read -r -p "请输入节点名称/别名 (回车默认 node-$pt): " node_tag
        [[ -z "$node_tag" ]] && node_tag="node-$pt"

        if [[ ! -f "$BP" ]]; then ins; fi
        mkdir -p "$CD" "$CR" "$ND"
        
        if [[ "$pc" =~ ^[3-9]$ ]]; then ic "$dm"; fi

        local default_uuid=$(if [[ ! -f "$BP" ]]; then ins; fi; $BP generate uuid)
        read -r -p "请输入 UUID 或密码 (回车自动生成): " ud
        [[ -z "$ud" ]] && ud="$default_uuid"

        local ip=$(curl -s4 -m 5 ip.sb)
        local co=""
        local si=""

        op $pt tcp
        op $pt udp

        local r_domain="www.microsoft.com"
        if [[ "$pc" == "1" || "$pc" == "2" ]]; then
            read -r -p "请输入 Reality 伪装目标域名 [默认: www.microsoft.com]: " custom_rd
            [[ -n "$custom_rd" ]] && r_domain="$custom_rd"
        fi

        if [[ "$pc" == "8" ]]; then
            read -r -p "是否启用 Hysteria2 端口跳跃? [y/N]: " enable_hop
            if [[ "$enable_hop" =~ ^[yY]$ ]]; then
                read -r -p "请输入端口跳跃范围 (例如 30000-40000): " hop_range
                if [[ -n "$hop_range" ]]; then
                    op "$hop_range" udp
                fi
            fi
        fi

        case "$pc" in
            1)
                local ks=$($BP generate reality-keypair)
                local pk=$(echo "$ks" | grep PrivateKey | awk '{print $2}'); local pb=$(echo "$ks" | grep PublicKey | awk '{print $2}')
                si="{\"type\": \"vless\",\"tag\": \"$node_tag\",\"listen\": \"::\",\"listen_port\": $pt,\"users\": [{\"uuid\": \"$ud\",\"flow\": \"xtls-rprx-vision\"}],\"tls\": {\"enabled\": true,\"server_name\": \"$r_domain\",\"reality\": {\"enabled\": true,\"handshake\": {\"server\": \"$r_domain\",\"server_port\": 443},\"private_key\": \"$pk\",\"short_id\": [\"\",\"6ba85179e30d4fc2\"]}}}"
                co="vless://${ud}@${ip}:${pt}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${r_domain}&fp=chrome&pbk=${pb}&sid=6ba85179e30d4fc2&type=tcp&headerType=none#${node_tag}"
                ;;
            2)
                local ks=$($BP generate reality-keypair)
                local pk=$(echo "$ks" | grep PrivateKey | awk '{print $2}'); local pb=$(echo "$ks" | grep PublicKey | awk '{print $2}')
                si="{\"type\": \"vless\",\"tag\": \"$node_tag\",\"listen\": \"::\",\"listen_port\": $pt,\"users\": [{\"uuid\": \"$ud\"}],\"transport\": {\"type\": \"grpc\",\"service_name\": \"grpc\"},\"tls\": {\"enabled\": true,\"server_name\": \"$r_domain\",\"reality\": {\"enabled\": true,\"handshake\": {\"server\": \"$r_domain\",\"server_port\": 443},\"private_key\": \"$pk\",\"short_id\": [\"\",\"6ba85179e30d4fc2\"]}}}"
                co="vless://${ud}@${ip}:${pt}?encryption=none&security=reality&sni=${r_domain}&fp=chrome&pbk=${pb}&sid=6ba85179e30d4fc2&type=grpc&serviceName=grpc#${node_tag}"
                ;;
            3)
                si="{\"type\": \"vless\",\"tag\": \"$node_tag\",\"listen\": \"::\",\"listen_port\": $pt,\"users\": [{\"uuid\": \"$ud\",\"flow\": \"xtls-rprx-vision\"}],\"tls\": {\"enabled\": true,\"server_name\": \"$dm\",\"certificate_path\": \"${CR}/fullchain.cer\",\"key_path\": \"${CR}/private.key\"}}"
                co="vless://${ud}@${dm}:${pt}?encryption=none&flow=xtls-rprx-vision&security=tls&sni=${dm}&fp=chrome&type=tcp&headerType=none#${node_tag}"
                ;;
            4)
                local ph="/$(tr -dc 'a-z0-9' </dev/urandom | head -c 6)ws"
                si="{\"type\": \"vless\",\"tag\": \"$node_tag\",\"listen\": \"::\",\"listen_port\": $pt,\"users\": [{\"uuid\": \"$ud\"}],\"transport\": {\"type\": \"ws\",\"path\": \"$ph\"},\"tls\": {\"enabled\": true,\"server_name\": \"$dm\",\"certificate_path\": \"${CR}/fullchain.cer\",\"key_path\": \"${CR}/private.key\"}}"
                co="vless://${ud}@${dm}:${pt}?encryption=none&security=tls&sni=${dm}&fp=chrome&type=ws&path=${ph}#${node_tag}"
                ;;
            5)
                local ph="/$(tr -dc 'a-z0-9' </dev/urandom | head -c 6)vws"
                si="{\"type\": \"vmess\",\"tag\": \"$node_tag\",\"listen\": \"::\",\"listen_port\": $pt,\"users\": [{\"uuid\": \"$ud\",\"alterId\": 0}],\"transport\": {\"type\": \"ws\",\"path\": \"$ph\"},\"tls\": {\"enabled\": true,\"server_name\": \"$dm\",\"certificate_path\": \"${CR}/fullchain.cer\",\"key_path\": \"${CR}/private.key\"}}"
                local vj="{\"v\":\"2\",\"ps\":\"${node_tag}\",\"add\":\"${dm}\",\"port\":${pt},\"id\":\"${ud}\",\"aid\":\"0\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"${dm}\",\"path\":\"${ph}\",\"tls\":\"tls\",\"sni\":\"${dm}\"}"
                co="vmess://$(echo -n "$vj" | base64 -w 0)"
                ;;
            6)
                local ph="/$(tr -dc 'a-z0-9' </dev/urandom | head -c 6)hup"
                si="{\"type\": \"vmess\",\"tag\": \"$node_tag\",\"listen\": \"::\",\"listen_port\": $pt,\"users\": [{\"uuid\": \"$ud\",\"alterId\": 0}],\"transport\": {\"type\": \"httpupgrade\",\"path\": \"$ph\"},\"tls\": {\"enabled\": true,\"server_name\": \"$dm\",\"certificate_path\": \"${CR}/fullchain.cer\",\"key_path\": \"${CR}/private.key\"}}"
                local vj="{\"v\":\"2\",\"ps\":\"${node_tag}\",\"add\":\"${dm}\",\"port\":${pt},\"id\":\"${ud}\",\"aid\":\"0\",\"net\":\"httpupgrade\",\"type\":\"none\",\"host\":\"${dm}\",\"path\":\"${ph}\",\"tls\":\"tls\",\"sni\":\"${dm}\"}"
                co="vmess://$(echo -n "$vj" | base64 -w 0)"
                ;;
            7)
                si="{\"type\": \"trojan\",\"tag\": \"$node_tag\",\"listen\": \"::\",\"listen_port\": $pt,\"users\": [{\"password\": \"$ud\"}],\"tls\": {\"enabled\": true,\"server_name\": \"$dm\",\"certificate_path\": \"${CR}/fullchain.cer\",\"key_path\": \"${CR}/private.key\"}}"
                co="trojan://${ud}@${dm}:${pt}?security=tls&sni=${dm}&fp=chrome&type=tcp#${node_tag}"
                ;;
            8)
                si="{\"type\": \"hysteria2\",\"tag\": \"$node_tag\",\"listen\": \"::\",\"listen_port\": $pt,\"users\": [{\"password\": \"$ud\"}],\"tls\": {\"enabled\": true,\"server_name\": \"$dm\",\"alpn\": [\"h3\"],\"certificate_path\": \"${CR}/fullchain.cer\",\"key_path\": \"${CR}/private.key\"}}"
                co="hysteria2://${ud}@${dm}:${pt}?peer=${dm}&insecure=0&sni=${dm}&alpn=h3#${node_tag}"
                ;;
            9)
                si="{\"type\": \"tuic\",\"tag\": \"$node_tag\",\"listen\": \"::\",\"listen_port\": $pt,\"users\": [{\"uuid\": \"$ud\", \"password\": \"$ud\"}],\"congestion_control\": \"bbr\",\"tls\": {\"enabled\": true,\"server_name\": \"$dm\",\"alpn\": [\"h3\"],\"certificate_path\": \"${CR}/fullchain.cer\",\"key_path\": \"${CR}/private.key\"}}"
                co="tuic://${ud}:${ud}@${dm}:${pt}?congestion_control=bbr&sni=${dm}&alpn=h3#${node_tag}"
                ;;
            10)
                si="{\"type\": \"socks\",\"tag\": \"$node_tag\",\"listen\": \"::\",\"listen_port\": $pt,\"users\": [{\"username\": \"$ud\", \"password\": \"$ud\"}]}"
                co="socks5://${ud}:${ud}@${ip}:${pt}#${node_tag}"
                ;;
        esac

        if [[ -f "$CS" ]]; then
            local existing=$(cat "$CS")
            local updated=$(echo "$existing" | jq --argjson new_in "$si" '.inbounds += [$new_in]')
            echo "$updated" > "$CS"
        else
            echo "{\"log\": {\"level\": \"info\"},\"inbounds\": [$si]}" > "$CS"
        fi

        echo "[$node_tag] $co" >> "$LK"

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
        echo -e "\n${G}服务端配置成功 (${node_tag})${P}"
        echo -e "${B}=== 单行节点链接 ===${P}"
        echo "$co"
        echo -e "${B}====================${P}"
        pause
    done
}

in_c() {
    mkdir -p "$ND"
    read -r -p "请输入节点保存名称 (如 us1): " na
    if [[ -z "$na" ]]; then echo -e "${R}不可为空${P}"; pause; return; fi
    read -r -p "粘贴节点链接: " uri
    if [[ -z "$uri" ]]; then echo -e "${R}不可为空${P}"; pause; return; fi

    local nj=$(u2j "$uri")
    if [[ -z "$nj" || "$nj" == "null" ]]; then
        echo -e "${R}解析失败：节点链接格式不支持或有误！${P}"; pause; return
    fi

    if [[ "$uri" == vmess://* ]]; then
        local vj=$(echo "${uri#vmess://}" | tr '_-' '/+' | base64 -d 2>/dev/null | jq -c ".ps=\"$na\"")
        uri="vmess://$(echo -n "$vj" | base64 -w 0)"
    else
        uri=$(echo "$uri" | awk -F'#' '{print $1}')
        uri="${uri}#${na}"
    fi

    echo "$uri" > "$ND/$na.uri"
    echo "$nj" > "$ND/$na.json"
    
    echo -e "${G}导入成功: $na${P}"
    pause
}

ls_c() {
    # 核心修复：客户端启用前检查并确保安装了 sing-box 内核
    if [[ ! -f "$BP" ]]; then
        echo -e "${Y}检测到本地未安装 sing-box 内核，正在自动安装...${P}"
        ins
    fi

    mkdir -p "$ND"
    local fs=("$ND"/*.uri)
    if [[ ${#fs[@]} -eq 0 || ! -f "${fs[0]}" ]]; then
        echo -e "${Y}暂无节点${P}"; pause; return
    fi

    echo -e "${B}--- 节点列表 ---${P}"
    for i in "${!fs[@]}"; do echo "$((i+1)). $(basename "${fs[$i]}" .uri)"; done
    echo "0. 返回"
    read -r -p "输入数字启用节点: " sel
    
    if [[ "$sel" == "0" ]]; then return; fi
    if [[ ! "$sel" =~ ^[0-9]+$ ]] || [ "$sel" -lt 1 ] || [ "$sel" -gt "${#fs[@]}" ]; then
        echo -e "${R}选错${P}"; sleep 1; ls_c; return
    fi

    local f="${fs[$((sel-1))]}"
    local na=$(basename "$f" .uri)
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
    systemctl restart sing-box-client && systemctl enable sing-box-client
    echo -e "${G}节点 [$na] 已启用，正在检测连通性...${P}"
    sleep 2
    
    local i4=$(curl -x socks5h://127.0.0.1:2080 -s4 -m 5 ip.sb 2>/dev/null)
    local go=$(curl -x socks5h://127.0.0.1:2080 -s -m 5 ipinfo.io/country 2>/dev/null)
    [[ -n "$i4" ]] && echo -e "IPv4: ${G}$i4${P} ($go)" || echo -e "IPv4: ${R}无${P}"
    
    local lat=$(curl -o /dev/null -s -w "%{time_total}\n" -m 5 -x socks5h://127.0.0.1:2080 https://www.google.com 2>/dev/null)
    if [[ -n "$lat" && "$lat" != "0.000" ]]; then
        echo -e "TCP: ${G}连通${P} (延迟: ${lat}秒)"
    else
        echo -e "TCP: ${R}失败${P}"
    fi

    if dig @8.8.8.8 google.com +time=3 +short >/dev/null 2>&1; then
        echo -e "UDP: ${G}连通${P} (DNS解析成功)"
    else
        echo -e "UDP: ${R}失败${P}"
    fi
    pause
}

ex_c() {
    mkdir -p "$ND"
    local fs=("$ND"/*.uri)
    if [[ ${#fs[@]} -eq 0 || ! -f "${fs[0]}" ]]; then echo -e "${Y}暂无节点${P}"; pause; return; fi
    echo -e "${B}--- 导出节点 ---${P}"
    for i in "${!fs[@]}"; do echo "$((i+1)). $(basename "${fs[$i]}" .uri)"; done
    echo "0. 返回"
    read -r -p "输入数字导出: " sel
    if [[ "$sel" == "0" ]]; then return; fi
    if [[ ! "$sel" =~ ^[0-9]+$ ]] || [ "$sel" -lt 1 ] || [ "$sel" -gt "${#fs[@]}" ]; then echo -e "${R}选错${P}"; sleep 1; ex_c; return; fi
    echo -e "\n${G}节点链接:${P}"
    cat "${fs[$((sel-1))]}"
    echo ""
    pause
}

rm_c() {
    mkdir -p "$ND"
    local fs=("$ND"/*.uri)
    if [[ ${#fs[@]} -eq 0 || ! -f "${fs[0]}" ]]; then echo -e "${Y}暂无节点${P}"; pause; return; fi
    echo -e "${B}--- 删除节点 ---${P}"
    for i in "${!fs[@]}"; do echo "$((i+1)). $(basename "${fs[$i]}" .uri)"; done
    echo "0. 返回"
    read -r -p "输入数字删除: " sel
    if [[ "$sel" == "0" ]]; then return; fi
    if [[ ! "$sel" =~ ^[0-9]+$ ]] || [ "$sel" -lt 1 ] || [ "$sel" -gt "${#fs[@]}" ]; then echo -e "${R}选错${P}"; sleep 1; rm_c; return; fi
    local na=$(basename "${fs[$((sel-1))]}" .uri)
    rm -f "${fs[$((sel-1))]}" "$ND/$na.json"
    echo -e "${G}已删除: $na${P}"
    pause
}

tg_c() {
    systemctl stop sing-box-client && systemctl disable sing-box-client
    echo -e "${Y}已断开，物理直连恢复${P}"
    pause
}

sc() {
    while true; do
        clear
        echo -e "${B}=====================================${P}"
        echo "1. 导入新节点"
        echo "2. 节点列表与启用"
        echo "3. 导出节点链接"
        echo "4. 关闭代理 (恢复直连)"
        echo "5. 删除节点"
        echo "0. 返回"
        echo -e "${B}=====================================${P}"
        read -r -p "选择: " cc
        case "$cc" in
            1) in_c ;;
            2) ls_c ;;
            3) ex_c ;;
            4) tg_c ;;
            5) rm_c ;;
            0) return ;;
            *) echo -e "${R}选错${P}"; sleep 1 ;;
        esac
    done
}

st() {
    clear
    echo -e "${B}--- 内核版本检查 ---${P}"
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

    echo -e "\n${B}--- 本机 IP (物理直连) ---${P}"
    local i4=$(curl -s4 -m 3 ip.sb)
    local i6=$(curl -s6 -m 3 ip.sb)
    local go=$(curl -s -m 3 ipinfo.io/country)
    [[ -n "$i4" ]] && echo -e "IPv4: ${G}$i4${P} ($go)" || echo -e "IPv4: ${R}无${P}"
    [[ -n "$i6" ]] && echo -e "IPv6: ${G}$i6${P}" || echo -e "IPv6: ${R}无${P}"

    echo -e "\n${B}--- 服务端运行协议与链接 ---${P}"
    if systemctl is-active --quiet sing-box; then
        echo -e "服务端状态: ${G}运行中${P}"
        if [[ -f "$CS" ]]; then
            echo -e "${B}当前运行的协议 inbounds:${P}"
            jq -r '.inbounds[] | " - 协议: \(.type) | 端口: \(.listen_port // "未知") | 标签: \(.tag // "无")"' "$CS" 2>/dev/null
        fi
        if [[ -f "$LK" ]]; then
            echo -e "\n${B}历史生成的分享链接:${P}"
            cat "$LK"
        fi
    else
        echo -e "服务端状态: ${R}未运行${P}"
    fi
    
    echo -e "\n${B}--- 客户端代理运行状态 ---${P}"
    if systemctl is-active --quiet sing-box-client; then 
        echo -e "客户端状态: ${G}代理中 (全局透明网卡接管)${P}"
        echo -e "\n${B}--- 代理过墙 IP ---${P}"
        local pi4=$(curl -x socks5h://127.0.0.1:2080 -s4 -m 5 ip.sb 2>/dev/null)
        local pi6=$(curl -x socks5h://127.0.0.1:2080 -s6 -m 5 ip.sb 2>/dev/null)
        local pgo=$(curl -x socks5h://127.0.0.1:2080 -s -m 5 ipinfo.io/country 2>/dev/null)
        [[ -n "$pi4" ]] && echo -e "IPv4: ${G}$pi4${P} ($pgo)" || echo -e "IPv4: ${R}无${P}"
        [[ -n "$pi6" ]] && echo -e "IPv6: ${G}$pi6${P}" || echo -e "IPv6: ${R}无${P}"
    else 
        echo -e "客户端: ${R}未运行 (当前网络为直连)${P}"
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
    pause
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

while true; do
    clear
    echo -e "${B}=====================================${P}"
    echo -e "${G}   Sing-box 管理面板${P}"
    echo -e "${B}=====================================${P}"
    echo "1. 服务端"
    echo "2. 客户端"
    echo "3. 状态"
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
        *) echo -e "${R}选错${P}"; sleep 1 ;;
    esac
done
