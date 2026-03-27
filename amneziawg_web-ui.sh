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
apt install -y nginx php8.1-fpm apache2-utils jq curl cron bc
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
$interface_section = "";
$peer_section = "";
$in_interface = false;
$in_peer = false;
$found = false;

// Собираем секцию Interface
foreach ($lines as $line) {
    if (preg_match('/^\[Interface\]/', $line)) {
        $in_interface = true;
        $interface_section = "[Interface]\n";
        continue;
    }
    if ($in_interface) {
        if (preg_match('/^\[Peer\]/', $line)) {
            $in_interface = false;
        } else {
            $interface_section .= $line . "\n";
        }
    }
}

// Ищем нужного Peer
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
                $client_config = $interface_section . "\n" . $peer_section;
                header('Content-Type: text/plain');
                header('Content-Disposition: attachment; filename="amneziawg-client.conf"');
                echo $client_config;
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

# Получаем данные
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
PEER_RX="—"
PEER_TX="—"
PEER_HANDSHAKE="никогда"

while IFS= read -r line; do
    if [[ "$line" =~ ^peer:\ (.+)$ ]]; then
        if [ -n "$CURRENT_PEER" ]; then
            CLIENTS+=("$CURRENT_PEER|$PEER_IP|$PEER_ENDPOINT|$PEER_RX|$PEER_TX|$PEER_HANDSHAKE")
        fi
        CURRENT_PEER="${BASH_REMATCH[1]}"
        PEER_IP="—"; PEER_ENDPOINT="—"; PEER_RX="—"; PEER_TX="—"; PEER_HANDSHAKE="никогда"
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

# Функция конвертации размера в байты
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

# Сортировки
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

# Читаем сохранённый тип сортировки
SORT_FILE="/var/www/amnezia-stats/sort.txt"
SORT_TYPE="ip"
[ -f "$SORT_FILE" ] && SORT_TYPE=$(cat "$SORT_FILE")

case "$SORT_TYPE" in
    ip) SORTED_CLIENTS=$(sort_by_ip) ;;
    rx) SORTED_CLIENTS=$(sort_by_rx) ;;
    tx) SORTED_CLIENTS=$(sort_by_tx) ;;
    *)  SORTED_CLIENTS=$(sort_by_ip) ;;
esac

# Считаем активных
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
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta http-equiv="refresh" content="30">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>AmneziaWG VPN Статистика</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: 'Segoe UI', 'Monaco', monospace;
            background: linear-gradient(135deg, #0a0e1a 0%, #0f1422 100%);
            color: #e4e4e7;
            padding: 20px;
            min-height: 100vh;
        }
        .container { max-width: 1400px; margin: 0 auto; }
        h1 {
            font-size: 2rem;
            background: linear-gradient(135deg, #60a5fa, #a78bfa);
            -webkit-background-clip: text;
            background-clip: text;
            color: transparent;
            margin-bottom: 10px;
        }
        .timestamp { color: #6b7280; margin-bottom: 30px; font-size: 0.9rem; }
        .stats-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 20px;
            margin-bottom: 30px;
        }
        .stat-card {
            background: rgba(17, 24, 39, 0.8);
            backdrop-filter: blur(10px);
            border: 1px solid rgba(96, 165, 250, 0.2);
            border-radius: 16px;
            padding: 20px;
        }
        .stat-label { font-size: 0.85rem; text-transform: uppercase; color: #94a3b8; margin-bottom: 10px; }
        .stat-number { font-size: 2.5rem; font-weight: bold; color: #60a5fa; }
        h2 { font-size: 1.3rem; color: #60a5fa; margin: 30px 0 20px 0; padding-bottom: 10px; border-bottom: 1px solid #1f2937; }
        .interface-info {
            background: #111827;
            border-radius: 16px;
            padding: 20px;
            margin-bottom: 30px;
            border: 1px solid #1f2937;
            overflow-x: auto;
        }
        .interface-info pre { margin: 0; font-size: 12px; white-space: pre-wrap; word-break: break-all; }
        table {
            width: 100%;
            border-collapse: collapse;
            background: #111827;
            border-radius: 16px;
            overflow: hidden;
        }
        th {
            background: #1f2a3e;
            padding: 14px 12px;
            text-align: left;
            color: #94a3b8;
            font-size: 0.85rem;
            text-transform: uppercase;
            cursor: pointer;
        }
        th:hover { background: #2d3a4e; }
        td {
            padding: 12px;
            border-bottom: 1px solid #1f2937;
            font-size: 0.85rem;
        }
        tr:hover { background: #1a2538; }
        .status-online { color: #4ade80; font-weight: bold; }
        .status-offline { color: #f87171; }
        .status-idle { color: #fbbf24; }
        .peer-key { font-family: monospace; font-size: 11px; background: #1f2937; padding: 2px 6px; border-radius: 6px; }
        .editable-name {
            cursor: pointer;
            background: #1f2937;
            padding: 4px 8px;
            border-radius: 6px;
            display: inline-block;
            transition: background 0.2s;
        }
        .editable-name:hover { background: #374151; }
        .download-btn {
            background: #3b82f6;
            border: none;
            color: white;
            padding: 4px 8px;
            border-radius: 6px;
            cursor: pointer;
            font-size: 0.75rem;
        }
        .download-btn:hover { background: #2563eb; }
        .name-input {
            background: #0f1422;
            border: 1px solid #60a5fa;
            color: #e4e4e7;
            padding: 4px 8px;
            border-radius: 6px;
            font-family: inherit;
            font-size: 0.85rem;
            width: 180px;
        }
        .save-btn {
            background: #60a5fa;
            border: none;
            color: #0a0e1a;
            padding: 4px 8px;
            border-radius: 6px;
            cursor: pointer;
            margin-left: 5px;
            font-size: 0.75rem;
        }
        .footer {
            margin-top: 40px;
            padding-top: 20px;
            text-align: center;
            color: #6b7280;
            font-size: 0.75rem;
            border-top: 1px solid #1f2937;
        }
        .note {
            background: #1f2a3e;
            padding: 10px 15px;
            border-radius: 8px;
            margin-top: 20px;
            font-size: 0.8rem;
            color: #94a3b8;
        }
        @media (max-width: 768px) {
            th, td { padding: 8px; font-size: 0.75rem; }
            .stat-number { font-size: 1.8rem; }
            .name-input { width: 120px; }
        }
    </style>
    <script>
        function editName(peerKey, currentName) {
            const cell = document.getElementById('name-cell-' + peerKey);
            cell.innerHTML = '<input type="text" id="name-input-' + peerKey + '" value="' + currentName.replace(/</g, '&lt;').replace(/>/g, '&gt;') + '" class="name-input" onkeypress="if(event.key===\'Enter\') saveName(\'' + peerKey + '\')"> ' +
                '<button class="save-btn" onclick="saveName(\'' + peerKey + '\')">💾</button> ' +
                '<button class="save-btn" onclick="location.reload()">✖</button>';
            document.getElementById('name-input-' + peerKey).focus();
        }
        function saveName(peerKey) {
            const newName = document.getElementById('name-input-' + peerKey).value.trim();
            if (!newName) return;
            fetch('/save_name.php', {method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:'peer='+encodeURIComponent(peerKey)+'&name='+encodeURIComponent(newName)})
            .then(r=>r.text()).then(d=>{if(d==='ok')location.reload();else alert('Ошибка')}).catch(()=>alert('Ошибка'));
        }
        function downloadConfig(peerKey) {
            window.location.href = '/get_config.php?peer=' + encodeURIComponent(peerKey);
        }
        function sortBy(type) {
            fetch('/sort.php?type=' + type)
                .then(() => location.reload())
                .catch(() => location.reload());
        }
    </script>
</head>
<body>
<div class="container">
    <h1>🔐 AmneziaWG VPN</h1>
    <div class="timestamp">📅 Последнее обновление: $(date '+%Y-%m-%d %H:%M:%S')</div>

    <div class="stats-grid">
        <div class="stat-card"><div class="stat-label">Всего клиентов</div><div class="stat-number">$PEER_COUNT</div></div>
        <div class="stat-card"><div class="stat-label">Активные (5 мин)</div><div class="stat-number">$ACTIVE_COUNT</div></div>
        <div class="stat-card"><div class="stat-label">VPN Порт</div><div class="stat-number">$WG_PORT</div></div>
    </div>

    <h2>📡 Интерфейс</h2>
    <div class="interface-info"><pre>$INTERFACE_INFO</pre></div>

    <h2>👥 Подключения клиентов</h2>
    <div style="overflow-x: auto;">
        表
            <thead>
                <tr>
                    <th onclick="sortBy('ip')">Имя</th>
                    <th>Статус</th>
                    <th onclick="sortBy('ip')">IP адрес</th>
                    <th>Публичный ключ</th>
                    <th>Endpoint</th>
                    <th onclick="sortBy('rx')">Получено</th>
                    <th onclick="sortBy('tx')">Отправлено</th>
                    <th>Последний handshake</th>
                    <th>Конфиг</th>
                 </tr>
            </thead>
            <tbody>
HTML

# Добавляем строки таблицы
while IFS='|' read -r peer_key peer_ip peer_ep peer_rx peer_tx peer_hs; do
    peer_name="${PEER_NAMES[$peer_key]}"
    [ -z "$peer_name" ] && peer_name="${peer_key:0:16}..."

    if [[ "$peer_hs" =~ [0-9]+[[:space:]]*seconds? ]]; then
        status="🟢 онлайн"
        status_class="status-online"
    elif [[ "$peer_hs" =~ [0-9]+[[:space:]]*minutes? ]] && [[ ! "$peer_hs" =~ [0-9]+[d] ]]; then
        status="🟡 недавно"
        status_class="status-idle"
    else
        status="⚫ офлайн"
        status_class="status-offline"
    fi

    echo "汽
        <td id=\"name-cell-${peer_key}\"><span class=\"editable-name\" onclick=\"editName('${peer_key}', '${peer_name//\'/\\\'}')\">📝 ${peer_name}</span>刷
        <td class=\"$status_class\">$status刷
        <td><code>${peer_ip:-—}</code>刷
        <td><span class=\"peer-key\">${peer_key:0:32}...</span>刷
        <td>${peer_ep:-—}刷
        <td>${peer_rx:-0}刷
        <td>${peer_tx:-0}刷
        <td>${peer_hs:-никогда}刷
        <td><button class=\"download-btn\" onclick=\"downloadConfig('${peer_key}')\">📥 Конфиг</button>刷
    </tr>" >> /var/www/amnezia-stats/index.html
done <<< "$SORTED_CLIENTS"

cat >> /var/www/amnezia-stats/index.html << HTML
            </tbody>
        表
    </div>

    <div class="note">
        💡 <strong>Примечание:</strong>
        <ul style="margin-left: 20px; margin-top: 5px;">
            <li>Кликните на имя клиента (📝) чтобы изменить отображаемое имя</li>
            <li>Кликните на заголовки "IP адрес", "Получено", "Отправлено" для сортировки</li>
            <li>Нажмите "📥 Конфиг" чтобы скачать конфигурационный файл клиента</li>
            <li>Имена сохраняются локально и не влияют на работу VPN</li>
        </ul>
    </div>

    <div class="footer">
        ⚡ Автообновление каждые 30 секунд • 🔒 AmneziaWG • Порт $WG_PORT/udp<br>
        📊 Данные из wg show
    </div>
</div>
</body>
</html>
HTML

echo "✅ Страница обновлена: $(date) | Всего клиентов: $PEER_COUNT"
EOF

chmod +x /usr/local/bin/gen_stats.sh
echo -e "${GREEN}✅ Генератор статистики создан${NC}"

# 8. Настраиваем Nginx
echo -e "\n${YELLOW}[8/10] Настройка Nginx...${NC}"
cat > /etc/nginx/sites-available/amnezia-stats << EOF
server {
    listen 9871;
    server_name _;

    root /var/www/amnezia-stats;
    index index.html index.php;

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