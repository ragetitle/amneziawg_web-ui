#!/bin/bash

set -e

echo "=== AmneziaWG Monitor FIXED ==="

read -p "Login [admin]: " AUTH_USER
AUTH_USER=${AUTH_USER:-admin}

read -sp "Password: " AUTH_PASS
echo ""
[ -z "$AUTH_PASS" ] && AUTH_PASS=$(openssl rand -base64 12)

echo "[1/8] Проверка контейнера..."
docker ps | grep -q amnezia-awg || { echo "No container"; exit 1; }

echo "[2/8] Установка..."
apt update
apt install -y nginx php8.1-fpm apache2-utils jq curl cron bc

mkdir -p /var/www/amnezia-stats
mkdir -p /usr/local/bin

htpasswd -bc /etc/nginx/.htpasswd "$AUTH_USER" "$AUTH_PASS"

echo "{}" > /var/www/amnezia-stats/peer_names.json
echo "ip" > /var/www/amnezia-stats/sort.txt

# ================= PHP =================

cat > /var/www/amnezia-stats/save_name.php << 'PHP'
<?php
$file = __DIR__ . '/peer_names.json';
$data = file_exists($file) ? json_decode(file_get_contents($file), true) : [];

$peer = $_POST['peer'] ?? '';
$name = trim($_POST['name'] ?? '');

if ($peer && $name) {
    $data[$peer] = $name;
    file_put_contents($file, json_encode($data, JSON_PRETTY_PRINT|JSON_UNESCAPED_UNICODE));
    echo "ok";
} else {
    echo "error";
}
PHP

cat > /var/www/amnezia-stats/sort.php << 'PHP'
<?php
file_put_contents(__DIR__.'/sort.txt', $_GET['type'] ?? 'ip');
echo "ok";
PHP

cat > /var/www/amnezia-stats/get_config.php << 'PHP'
<?php
$peer_key = $_GET['peer'] ?? '';
if (!$peer_key) die("no key");

$config = shell_exec("docker exec amnezia-awg cat /opt/amnezia/awg/wg0.conf");
$lines = explode("\n", $config);

$interface = "";
$peers = [];
$current = "";
$mode = "";

foreach ($lines as $line) {

    if (trim($line) === "[Interface]") {
        $mode = "i";
        continue;
    }

    if (trim($line) === "[Peer]") {
        if ($current) $peers[] = $current;
        $current = "[Peer]\n";
        $mode = "p";
        continue;
    }

    if ($mode === "i") $interface .= $line."\n";
    if ($mode === "p") $current .= $line."\n";
}

if ($current) $peers[] = $current;

foreach ($peers as $peer) {
    if (strpos($peer, $peer_key) !== false) {

        header('Content-Type: text/plain');
        header('Content-Disposition: attachment; filename="client.conf"');

        echo "[Interface]\n";
        echo trim($interface)."\n\n";
        echo trim($peer);
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
        ip=""; rx="0"; tx="0"

    elif [[ $line == *"allowed ips:"* ]]; then
        ip=$(echo $line | awk '{print $3}')

    elif [[ $line == *"transfer:"* ]]; then
        rx=$(echo $line | awk '{print $2}')
        tx=$(echo $line | awk '{print $4}')

        CLIENTS+=("$key|$ip|$rx|$tx")
    fi
done <<< "$WG"

SORT=$(cat /var/www/amnezia-stats/sort.txt)

if [ "$SORT" = "rx" ]; then
    CLIENTS=($(printf "%s\n" "${CLIENTS[@]}" | sort -t'|' -k3 -r))
elif [ "$SORT" = "tx" ]; then
    CLIENTS=($(printf "%s\n" "${CLIENTS[@]}" | sort -t'|' -k4 -r))
else
    CLIENTS=($(printf "%s\n" "${CLIENTS[@]}" | sort -t'|' -k2))
fi

cat > /var/www/amnezia-stats/index.html <<HTML
<html><head>
<meta charset="utf-8">
<script>
function save(k){
let v=document.getElementById(k).value;
fetch('/save_name.php',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:'peer='+k+'&name='+v}).then(()=>location.reload());
}
function sort(t){fetch('/sort.php?type='+t).then(()=>location.reload());}
</script>
</head><body>

<table border=1>
<tr>
<th>Имя</th>
<th onclick="sort('ip')">IP</th>
<th onclick="sort('rx')">RX</th>
<th onclick="sort('tx')">TX</th>
<th>CFG</th>
</tr>
HTML

for c in "${CLIENTS[@]}"; do
IFS='|' read key ip rx tx <<< "$c"

safe=$(echo "$key" | base64 | tr -d '=' | tr '/+' '_-')
name=${NAMES[$safe]}

echo "<tr>
<td><input id='$safe' value='$name'><button onclick=\"save('$safe')\">ok</button></td>
<td>$ip</td>
<td>$rx</td>
<td>$tx</td>
<td><a href='/get_config.php?peer=$key'>cfg</a></td>
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

echo ""
echo "DONE:"
echo "http://$IP:9871"
echo "login: $AUTH_USER"
echo "pass: $AUTH_PASS"