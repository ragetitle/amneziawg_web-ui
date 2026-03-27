#!/bin/bash

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=== AmneziaWG Monitor PRO (FIXED) ===${NC}"

read -p "Логин [admin]: " AUTH_USER
AUTH_USER=${AUTH_USER:-admin}

read -sp "Пароль: " AUTH_PASS
echo ""
[ -z "$AUTH_PASS" ] && AUTH_PASS=$(openssl rand -base64 12)

echo -e "${YELLOW}[1] Проверка контейнера...${NC}"
docker ps | grep -q amnezia-awg || { echo "❌ Контейнер не найден"; exit 1; }

echo -e "${YELLOW}[2] Установка зависимостей...${NC}"
apt update
apt install -y nginx php8.1-fpm apache2-utils jq curl cron bc

mkdir -p /var/www/amnezia-stats
mkdir -p /usr/local/bin

echo "{}" > /var/www/amnezia-stats/peer_names.json
echo "ip" > /var/www/amnezia-stats/sort.txt
chmod 666 /var/www/amnezia-stats/*

htpasswd -bc /etc/nginx/.htpasswd "$AUTH_USER" "$AUTH_PASS"

# ================= PHP =================

cat > /var/www/amnezia-stats/save_name.php << 'PHP'
<?php
$file = __DIR__.'/peer_names.json';
$data = file_exists($file) ? json_decode(file_get_contents($file), true) : [];

$peer = $_POST['peer'] ?? '';
$name = trim($_POST['name'] ?? '');

if ($peer && $name) {
    $data[$peer] = $name;
    file_put_contents($file, json_encode($data, JSON_PRETTY_PRINT|JSON_UNESCAPED_UNICODE));
    echo "ok";
} else echo "error";
PHP

cat > /var/www/amnezia-stats/sort.php << 'PHP'
<?php
file_put_contents(__DIR__.'/sort.txt', $_GET['type'] ?? 'ip');
echo "ok";
PHP

cat > /var/www/amnezia-stats/get_config.php << 'PHP'
<?php
$key = $_GET['peer'] ?? '';
if (!$key) die('no key');

$config = shell_exec("docker exec amnezia-awg cat /opt/amnezia/awg/wg0.conf");
$lines = explode("\n",$config);

$interface=""; $peers=[]; $cur=""; $mode="";

foreach($lines as $l){
    if(trim($l)=="[Interface]"){ $mode="i"; continue; }
    if(trim($l)=="[Peer]"){
        if($cur) $peers[]=$cur;
        $cur="[Peer]\n"; $mode="p"; continue;
    }
    if($mode=="i") $interface.=$l."\n";
    if($mode=="p") $cur.=$l."\n";
}
if($cur) $peers[]=$cur;

foreach($peers as $p){
    if(strpos($p,$key)!==false){
        header('Content-Type:text/plain');
        header('Content-Disposition:attachment;filename=client.conf');
        echo "[Interface]\n".trim($interface)."\n\n".trim($p);
        exit;
    }
}
echo "not found";
PHP

# ================= GENERATOR =================

cat > /usr/local/bin/gen_stats.sh << 'BASH'
#!/bin/bash

WG=$(docker exec amnezia-awg wg show)

declare -A NAMES
[ -f /var/www/amnezia-stats/peer_names.json ] && \
while read line; do
    k=$(echo $line | cut -d: -f1)
    v=$(echo $line | cut -d: -f2-)
    NAMES[$k]=$v
done < <(jq -r 'to_entries[] | "\(.key):\(.value)"' /var/www/amnezia-stats/peer_names.json)

CLIENTS=()

while read line; do
    if [[ $line == peer:* ]]; then
        key=$(echo $line | awk '{print $2}')
        ip="—"; rx="0"; tx="0"; hs="никогда"; ep="—"
    elif [[ $line == *"allowed ips:"* ]]; then
        ip=$(echo $line | awk '{print $3}')
    elif [[ $line == *"endpoint:"* ]]; then
        ep=$(echo $line | cut -d' ' -f2-)
    elif [[ $line == *"transfer:"* ]]; then
        rx=$(echo $line | awk '{print $2}')
        tx=$(echo $line | awk '{print $4}')
    elif [[ $line == *"latest handshake:"* ]]; then
        hs=$(echo $line | cut -d: -f2-)
        CLIENTS+=("$key|$ip|$ep|$rx|$tx|$hs")
    fi
done <<< "$WG"

SORT=$(cat /var/www/amnezia-stats/sort.txt 2>/dev/null || echo ip)

case $SORT in
    rx) CLIENTS=($(printf "%s\n" "${CLIENTS[@]}" | sort -t'|' -k4 -r));;
    tx) CLIENTS=($(printf "%s\n" "${CLIENTS[@]}" | sort -t'|' -k5 -r));;
    *) CLIENTS=($(printf "%s\n" "${CLIENTS[@]}" | sort -t'|' -k2));;
esac

cat > /var/www/amnezia-stats/index.html <<HTML
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta http-equiv="refresh" content="30">
<title>VPN</title>
<script>
function save(k){
let v=document.getElementById('i_'+k).value;
fetch('/save_name.php',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:'peer='+k+'&name='+v}).then(()=>location.reload());
}
function sort(t){fetch('/sort.php?type='+t).then(()=>location.reload());}
</script>
</head>
<body>

<table border=1>
<tr>
<th>Имя</th>
<th onclick="sort('ip')">IP</th>
<th>Endpoint</th>
<th onclick="sort('rx')">RX</th>
<th onclick="sort('tx')">TX</th>
<th>HS</th>
<th>CFG</th>
</tr>
HTML

for c in "${CLIENTS[@]}"; do
IFS='|' read key ip ep rx tx hs <<< "$c"

safe=$(echo "$key" | base64 | tr -d '=' | tr '/+' '_-')
name=${NAMES[$safe]}

echo "<tr>
<td><input id='i_$safe' value='$name'><button onclick=\"save('$safe')\">💾</button></td>
<td>$ip</td>
<td>$ep</td>
<td>$rx</td>
<td>$tx</td>
<td>$hs</td>
<td><a href='/get_config.php?peer=$key'>📥</a></td>
</tr>" >> /var/www/amnezia-stats/index.html

done

echo "</table></body></html>" >> /var/www/amnezia-stats/index.html
BASH

chmod +x /usr/local/bin/gen_stats.sh

# ================= NGINX =================

cat > /etc/nginx/sites-available/amnezia <<EOF
server {
    listen 9871;
    root /var/www/amnezia-stats;
    index index.html index.php;

    auth_basic "VPN";
    auth_basic_user_file /etc/nginx/.htpasswd;

    location / { try_files \$uri \$uri/ =404; }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php8.1-fpm.sock;
    }
}
EOF

ln -sf /etc/nginx/sites-available/amnezia /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

nginx -t
systemctl restart nginx

# ================= CRON =================

(crontab -l 2>/dev/null; echo "* * * * * /usr/local/bin/gen_stats.sh") | crontab -

/usr/local/bin/gen_stats.sh

IP=$(curl -s ifconfig.me)

echo -e "\n${GREEN}ГОТОВО:${NC} http://$IP:9871"
echo "логин: $AUTH_USER"
echo "пароль: $AUTH_PASS"