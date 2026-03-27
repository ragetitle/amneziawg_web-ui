#!/bin/bash

# ============================================
# AmneziaWG Monitor PRO - финальная версия
# ============================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}AmneziaWG Monitor PRO${NC}"
echo -e "${GREEN}========================================${NC}"

# Запрашиваем данные
echo -e "\n${YELLOW}Настройка авторизации:${NC}"
read -p "Введите логин для доступа к панели [admin]: " AUTH_USER
AUTH_USER=${AUTH_USER:-admin}

read -sp "Введите пароль для доступа к панели: " AUTH_PASS
echo ""
if [ -z "$AUTH_PASS" ]; then
    AUTH_PASS=$(openssl rand -base64 12)
    echo -e "${YELLOW}Пароль сгенерирован: ${GREEN}$AUTH_PASS${NC}"
fi

# 1. Проверяем контейнер
echo -e "\n${YELLOW}[1/10] Проверка контейнера amnezia-awg...${NC}"
if ! docker ps | grep -q "amnezia-awg"; then
    echo -e "${RED}❌ Контейнер amnezia-awg не запущен!${NC}"
    exit 1
fi
echo -e "${GREEN}✅ Контейнер amnezia-awg запущен${NC}"

# 2. Определяем порт
echo -e "\n${YELLOW}[2/10] Определение порта AmneziaWG...${NC}"
WG_PORT=$(docker exec amnezia-awg cat /opt/amnezia/awg/wg0.conf 2>/dev/null | grep "^ListenPort" | awk '{print $3}')
[ -z "$WG_PORT" ] && WG_PORT=$(docker exec amnezia-awg wg show 2>/dev/null | grep "listening port:" | awk '{print $3}')
[ -z "$WG_PORT" ] && WG_PORT="42441"
echo -e "${GREEN}✅ Обнаружен порт: $WG_PORT${NC}"

# 3. Устанавливаем зависимости
echo -e "\n${YELLOW}[3/10] Установка зависимостей...${NC}"
apt update
apt install -y nginx php8.1-fpm apache2-utils jq curl cron
echo -e "${GREEN}✅ Зависимости установлены${NC}"

# 4. Создаём директории
echo -e "\n${YELLOW}[4/10] Создание директорий...${NC}"
mkdir -p /var/www/amnezia-stats
mkdir -p /usr/local/bin
echo -e "${GREEN}✅ Директории созданы${NC}"

# 5. Настраиваем авторизацию
echo -e "\n${YELLOW}[5/10] Настройка авторизации...${NC}"
htpasswd -bc /etc/nginx/.htpasswd "$AUTH_USER" "$AUTH_PASS"
echo -e "${GREEN}✅ Авторизация настроена${NC}"

# 6. Создаём PHP обработчики
echo -e "\n${YELLOW}[6/10] Создание обработчиков...${NC}"

cat > /var/www/amnezia-stats/save_name.php << 'EOF'
<?php
$file = __DIR__ . '/peer_names.json';
$names = [];
if (file_exists($file)) {
    $content = file_get_contents($file);
    $names = json_decode($content, true) ?: [];
}
if (isset($_POST['peer']) && isset($_POST['name'])) {
    $peer = $_POST['peer'];
    $name = trim($_POST['name']);
    if (!empty($name)) {
        $names[$peer] = $name;
        file_put_contents($file, json_encode($names, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE));
        echo 'ok';
    } else {
        echo 'error';
    }
} else {
    echo 'error';
}
?>
EOF

cat > /var/www/amnezia-stats/get_config.php << 'EOF'
<?php
$peer_key = isset($_GET['peer']) ? $_GET['peer'] : '';
if (empty($peer_key)) {
    http_response_code(400);
    die('Peer key required');
}
$config = shell_exec("docker exec amnezia-awg cat /opt/amnezia/awg/wg0.conf 2>/dev/null");
if (empty($config)) {
    http_response_code(500);
    die('Cannot read config');
}
$lines = explode("\n", $config);
$peer_section = "";
$in_peer = false;
$found = false;
foreach ($lines as $line) {
    if (preg_match('/^\[Peer\]/', $line)) {
        $in_peer = true;
        $peer_section = "[Peer]\n";
        continue;
    }
    if ($in_peer) {
        $peer_section .= $line . "\n";
        if (preg_match('/PublicKey\s*=\s*' . preg_quote($peer_key, '/') . '/', $line)) {
            $found = true;
        }
        if (trim($line) === "" || preg_match('/^\[/', $line)) {
            if ($found) {
                $interface = shell_exec("docker exec amnezia-awg cat /opt/amnezia/awg/wg0.conf 2>/dev/null | grep -A 20 '^\[Interface\]' | head -20");
                $full_config = $interface . "\n" . $peer_section;
                header('Content-Type: text/plain');
                header('Content-Disposition: attachment; filename="amneziawg-client.conf"');
                echo $full_config;
                exit;
            }
            $in_peer = false;
            $peer_section = "";
            $found = false;
        }
    }
}
http_response_code(404);
die('Peer not found');
?>
EOF

cat > /var/www/amnezia-stats/sort.php << 'EOF'
<?php
$type = isset($_GET['type']) ? $_GET['type'] : 'ip';
file_put_contents(__DIR__ . '/sort.txt', $type);
header('Content-Type: application/json');
echo json_encode(['status' => 'ok']);
?>
EOF

if [ ! -f "/var/www/amnezia-stats/peer_names.json" ]; then
    echo "{}" > /var/www/amnezia-stats/peer_names.json
fi
chmod 644 /var/www/amnezia-stats/*
echo -e "${GREEN}✅ Обработчики созданы${NC}"

# 7. Создаём генератор статистики
echo -e "\n${YELLOW}[7/10] Создание генератора статистики...${NC}"
cat > /usr/local/bin/gen_stats.sh << 'EOF'
#!/bin/bash

WG_OUTPUT=$(docker exec amnezia-awg wg show 2>&1)
PEER_COUNT=$(echo "$WG_OUTPUT" | grep -c "^peer:")
WG_PORT=$(docker exec amnezia-awg cat /opt/amnezia/awg/wg0.conf 2>/dev/null | grep "^ListenPort" | awk '{print $3}')
[ -z "$WG_PORT" ] && WG_PORT=$(echo "$WG_OUTPUT" | grep "listening port:" | awk '{print $3}')
[ -z "$WG_PORT" ] && WG_PORT="42441"
INTERFACE_INFO=$(echo "$WG_OUTPUT" | head -13)

# Загружаем имена
declare -A PEER_NAMES
if [ -f "/var/www/amnezia-stats/peer_names.json" ] && command -v jq >/dev/null; then
    while IFS= read -r line; do
        key=$(echo "$line" | cut -d: -f1)
        name=$(echo "$line" | cut -d: -f2-)
        PEER_NAMES["$key"]="$name"
    done < <(jq -r 'to_entries | .[] | "\(.key):\(.value)"' /var/www/amnezia-stats/peer_names.json 2>/dev/null)
fi

# Парсим клиентов
CLIENTS=()
CURRENT_PEER=""
PEER_IP="—"
PEER_ENDPOINT="—"
PEER_RX="0"
PEER_TX="0"
PEER_HANDSHAKE="никогда"

while IFS= read -r line; do
    if [[ "$line" =~ ^peer:\ (.+)$ ]]; then
        if [ -n "$CURRENT_PEER" ]; then
            CLIENTS+=("$CURRENT_PEER|$PEER_IP|$PEER_ENDPOINT|$PEER_RX|$PEER_TX|$PEER_HANDSHAKE")
        fi
        CURRENT_PEER="${BASH_REMATCH[1]}"
        PEER_IP="—"; PEER_ENDPOINT="—"; PEER_RX="0"; PEER_TX="0"; PEER_HANDSHAKE="никогда"
    elif [ -n "$CURRENT_PEER" ]; then
        [[ "$line" =~ allowed\ ips:\ ([0-9./]+) ]] && PEER_IP="${BASH_REMATCH[1]}"
        [[ "$line" =~ endpoint:\ (.+) ]] && PEER_ENDPOINT="${BASH_REMATCH[1]}"
        [[ "$line" =~ transfer:\ (.+)\ received,\ (.+)\ sent ]] && PEER_RX="${BASH_REMATCH[1]}" && PEER_TX="${BASH_REMATCH[2]}"
        [[ "$line" =~ latest\ handshake:\ (.+) ]] && PEER_HANDSHAKE="${BASH_REMATCH[1]}"
    fi
done <<< "$WG_OUTPUT"
if [ -n "$CURRENT_PEER" ]; then
    CLIENTS+=("$CURRENT_PEER|$PEER_IP|$PEER_ENDPOINT|$PEER_RX|$PEER_TX|$PEER_HANDSHAKE")
fi

# Сортировка
bytes_to_int() {
    local size="$1"
    if [[ "$size" =~ ([0-9.]+)[[:space:]]*([KMGT]?B?) ]]; then
        local val=${BASH_REMATCH[1]}
        local unit=${BASH_REMATCH[2]}
        case "$unit" in
            KB|K) echo "$val * 1024" | bc | cut -d. -f1 ;;
            MB|M) echo "$val * 1048576" | bc | cut -d. -f1 ;;
            GB|G) echo "$val * 1073741824" | bc | cut -d. -f1 ;;
            *) echo "$val" ;;
        esac
    else
        echo "0"
    fi
}

sort_by_ip() { printf '%s\n' "${CLIENTS[@]}" | sort -t'|' -k2 -V; }
sort_by_rx() {
    printf '%s\n' "${CLIENTS[@]}" | while IFS='|' read -r key ip ep rx tx hs; do
        echo "$(bytes_to_int "$rx")|$key|$ip|$ep|$rx|$tx|$hs"
    done | sort -t'|' -k1 -rn | cut -d'|' -f2-
}
sort_by_tx() {
    printf '%s\n' "${CLIENTS[@]}" | while IFS='|' read -r key ip ep rx tx hs; do
        echo "$(bytes_to_int "$tx")|$key|$ip|$ep|$rx|$tx|$hs"
    done | sort -t'|' -k1 -rn | cut -d'|' -f2-
}

SORT_FILE="/var/www/amnezia-stats/sort.txt"
SORT_TYPE="ip"
[ -f "$SORT_FILE" ] && SORT_TYPE=$(cat "$SORT_FILE")

case "$SORT_TYPE" in
    ip) SORTED=$(sort_by_ip) ;;
    rx) SORTED=$(sort_by_rx) ;;
    tx) SORTED=$(sort_by_tx) ;;
    *)  SORTED=$(sort_by_ip) ;;
esac

# Активные
ACTIVE_COUNT=0
for client in "${CLIENTS[@]}"; do
    IFS='|' read -r _ _ _ _ _ hs <<< "$client"
    if [[ "$hs" =~ [0-9]+[[:space:]]*seconds? ]] || [[ "$hs" =~ [0-9]+[[:space:]]*minutes? ]] && [[ ! "$hs" =~ [0-9]+[d] ]]; then
        ((ACTIVE_COUNT++))
    fi
done

# Генерируем HTML
cat > /var/www/amnezia-stats/index.html << HTML
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <meta http-equiv="refresh" content="30">
    <title>AmneziaWG VPN</title>
    <style>
        body{background:#0a0e1a;color:#e4e4e7;font-family:monospace;padding:20px}
        h1,h2{color:#60a5fa}
        .stats{display:flex;gap:20px;margin:20px 0}
        .stat-card{background:#111827;padding:15px 25px;border-radius:12px}
        .stat-number{font-size:2em;color:#60a5fa}
        table{border-collapse:collapse;width:100%;background:#111827}
        th,td{border:1px solid #1f2937;padding:10px;text-align:left}
        th{background:#1f2a3e;cursor:pointer}
        th:hover{background:#2d3a4e}
        .online{color:#4ade80}
        .offline{color:#f87171}
        .download-btn{background:#3b82f6;border:none;color:white;padding:4px 8px;border-radius:6px;cursor:pointer}
        .editable-name{cursor:pointer;background:#1f2937;padding:4px 8px;border-radius:6px;display:inline-block}
        .footer{font-size:12px;color:#6b7280;text-align:center;margin-top:30px}
        .note{background:#1f2a3e;padding:10px;border-radius:8px;margin-top:20px}
        .name-input{background:#0f1422;border:1px solid #60a5fa;color:#e4e4e7;padding:4px 8px;border-radius:6px}
        .save-btn{background:#60a5fa;border:none;padding:4px 8px;border-radius:6px;cursor:pointer}
    </style>
    <script>
        function editName(peerKey, currentName) {
            const cell = document.getElementById('name-cell-'+peerKey);
            cell.innerHTML = '<input type="text" id="name-input-'+peerKey+'" value="'+currentName+'" class="name-input"> <button class="save-btn" onclick="saveName(\''+peerKey+'\')">💾</button>';
            document.getElementById('name-input-'+peerKey).focus();
        }
        function saveName(peerKey) {
            const newName = document.getElementById('name-input-'+peerKey).value.trim();
            if(!newName) return;
            fetch('/save_name.php',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:'peer='+encodeURIComponent(peerKey)+'&name='+encodeURIComponent(newName)})
            .then(r=>r.text()).then(d=>{if(d==='ok')location.reload()});
        }
        function downloadConfig(peerKey){window.location.href='/get_config.php?peer='+encodeURIComponent(peerKey);}
        function sortBy(type){fetch('/sort.php?type='+type).then(()=>location.reload());}
    </script>
</head>
<body>
<h1>🔐 AmneziaWG VPN</h1>
<p>Обновлено: $(date '+%Y-%m-%d %H:%M:%S')</p>
<div class="stats">
    <div class="stat-card"><div class="stat-number">$PEER_COUNT</div><div>Клиентов</div></div>
    <div class="stat-card"><div class="stat-number">$ACTIVE_COUNT</div><div>Активных</div></div>
    <div class="stat-card"><div class="stat-number">$WG_PORT</div><div>Порт VPN</div></div>
</div>
<h2>📡 Интерфейс</h2>
<pre>$INTERFACE_INFO</pre>
<h2>👥 Клиенты</h2>
<table>
    <thead><tr>
        <th onclick="sortBy('ip')">Имя</th>
        <th>Статус</th>
        <th onclick="sortBy('ip')">IP</th>
        <th>Ключ</th>
        <th>Endpoint</th>
        <th onclick="sortBy('rx')">Получено</th>
        <th onclick="sortBy('tx')">Отправлено</th>
        <th>Handshake</th>
        <th></th>
    </tr></thead>
    <tbody>
HTML

while IFS='|' read -r key ip ep rx tx hs; do
    name="${PEER_NAMES[$key]}"
    [ -z "$name" ] && name="${key:0:16}..."
    if [[ "$hs" =~ [0-9]+[[:space:]]*seconds? ]]; then
        status="🟢 онлайн"
        status_class="online"
    elif [[ "$hs" =~ [0-9]+[[:space:]]*minutes? ]] && [[ ! "$hs" =~ [0-9]+[d] ]]; then
        status="🟡 недавно"
        status_class="online"
    else
        status="⚫ офлайн"
        status_class="offline"
    fi
    echo "<tr>
        <td id=\"name-cell-${key}\"><span class=\"editable-name\" onclick=\"editName('${key}','${name//\'/\\\'}')\">📝 ${name}</span></td>
        <td class=\"$status_class\">$status</td>
        <td><code>$ip</code></td>
        <td><code>${key:0:32}...</code></td>
        <td>$ep</td>
        <td>$rx</td>
        <td>$tx</td>
        <td>$hs</td>
        <td><button class=\"download-btn\" onclick=\"downloadConfig('${key}')\">📥</button></td>
    </tr>" >> /var/www/amnezia-stats/index.html
done <<< "$SORTED"

cat >> /var/www/amnezia-stats/index.html << HTML
    </tbody>
</table>
<div class="note">💡 Клик по имени — редактировать, по заголовкам — сортировка, 📥 — скачать конфиг</div>
<div class="footer">⚡ Автообновление 30 сек • Порт $WG_PORT/udp</div>
</body>
</html>
HTML

echo "✅ Страница обновлена: $(date) | Клиентов: $PEER_COUNT"
EOF

chmod +x /usr/local/bin/gen_stats.sh
echo -e "${GREEN}✅ Генератор создан${NC}"

# 8. Настраиваем Nginx
echo -e "\n${YELLOW}[8/10] Настройка Nginx...${NC}"
cat > /etc/nginx/sites-available/amnezia-stats << EOF
server {
    listen 9871;
    root /var/www/amnezia-stats;
    index index.html;

    auth_basic "AmneziaWG Monitor";
    auth_basic_user_file /etc/nginx/.htpasswd;

    location / {
        try_files \$uri \$uri/ =404;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php8.1-fpm.sock;
    }
}
EOF

ln -sf /etc/nginx/sites-available/amnezia-stats /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl restart nginx
echo -e "${GREEN}✅ Nginx настроен на порт 9871${NC}"

# 9. Настраиваем cron
echo -e "\n${YELLOW}[9/10] Настройка автообновления...${NC}"
(crontab -l 2>/dev/null | grep -v gen_stats.sh; echo "* * * * * /usr/local/bin/gen_stats.sh") | crontab -
(crontab -l 2>/dev/null | grep -v "sleep 30"; echo "* * * * * sleep 30; /usr/local/bin/gen_stats.sh") | crontab -
systemctl restart cron

# 10. Запускаем
echo -e "\n${YELLOW}[10/10] Запуск...${NC}"
/usr/local/bin/gen_stats.sh

SERVER_IP=$(curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')

echo -e "\n${GREEN}========================================${NC}"
echo -e "${GREEN}✅ УСТАНОВКА ЗАВЕРШЕНА!${NC}"
echo -e "${GREEN}========================================${NC}"
echo -e "\n${YELLOW}🌐 Панель:${NC} ${GREEN}http://${SERVER_IP}:9871${NC}"
echo -e "${YELLOW}🔑 Логин:${NC} ${GREEN}$AUTH_USER${NC}"
echo -e "${YELLOW}🔑 Пароль:${NC} ${GREEN}$AUTH_PASS${NC}"
echo -e "\n${GREEN}========================================${NC}"