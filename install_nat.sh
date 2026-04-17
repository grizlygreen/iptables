#!/usr/bin/env bash
set -euo pipefail

#################################
# TRAP
#################################
trap 'echo -e "\033[1;31m[ERROR]\033[0m Ошибка в строке $LINENO"; exit 1' ERR

#################################
# HELPERS
#################################
log()  { echo -e "\033[1;32m[INFO]\033[0m $1"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $1"; }
die()  { echo -e "\033[1;31m[ERROR]\033[0m $1"; exit 1; }

CONFIG_FILE="/etc/nat-forwarder.conf"
BACKUP_DIR="/etc/ufw/backups"
LOG_FILE="/var/log/nat-forwarder.log"

log_to_file() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

#################################
# ВАЛИДАЦИЯ IP
#################################
validate_ip() {
    local ip="$1"
    local IFS='.'
    read -ra octets <<< "$ip"
    [[ ${#octets[@]} -eq 4 ]] || return 1
    for octet in "${octets[@]}"; do
        [[ "$octet" =~ ^[0-9]+$ ]] || return 1
        (( octet >= 0 && octet <= 255 )) || return 1
    done
    return 0
}

#################################
# ВАЛИДАЦИЯ ПОРТОВ
#################################
validate_ports() {
    local input="$1"
    # Допускает: 443 | 443,8443,2222 | 8000:9000 | 443,8000:9000
    local IFS=','
    read -ra parts <<< "$input"
    for part in "${parts[@]}"; do
        if [[ "$part" =~ ^([0-9]+):([0-9]+)$ ]]; then
            local start="${BASH_REMATCH[1]}" end="${BASH_REMATCH[2]}"
            (( start >= 1 && start <= 65535 && end >= 1 && end <= 65535 && start <= end )) || return 1
        elif [[ "$part" =~ ^[0-9]+$ ]]; then
            (( part >= 1 && part <= 65535 )) || return 1
        else
            return 1
        fi
    done
    return 0
}

#################################
# ПОКАЗ СТАТУСА
#################################
show_status() {
    echo ""
    echo "=== NAT Forwarder — текущее состояние ==="
    echo ""

    if [[ -f "$CONFIG_FILE" ]]; then
        log "Конфигурация ($CONFIG_FILE):"
        while IFS='=' read -r key value; do
            [[ -z "$key" || "$key" =~ ^# ]] && continue
            echo "  $key = $value"
        done < "$CONFIG_FILE"
    else
        warn "Конфигурация не найдена ($CONFIG_FILE)"
    fi

    echo ""
    log "NAT-правила (iptables -t nat):"
    iptables -t nat -L PREROUTING -n --line-numbers 2>/dev/null | grep -E "DNAT|dpt" || echo "  (нет правил DNAT)"
    echo ""
    iptables -t nat -L POSTROUTING -n --line-numbers 2>/dev/null | grep -E "SNAT|MASQ" || echo "  (нет правил SNAT)"

    echo ""
    log "FORWARD-правила:"
    iptables -L FORWARD -n --line-numbers 2>/dev/null | grep -v "^Chain\|^num" | head -20 || echo "  (нет правил)"

    echo ""
    log "Conntrack:"
    local ct_cur ct_max
    ct_cur=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo "N/A")
    ct_max=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo "N/A")
    echo "  Текущих соединений: $ct_cur / $ct_max"

    if [[ "$ct_max" != "N/A" && "$ct_cur" != "N/A" ]]; then
        local pct=$(( ct_cur * 100 / ct_max ))
        if (( pct > 80 )); then
            warn "Conntrack заполнен на ${pct}%!"
        else
            log "Conntrack: ${pct}% использовано"
        fi
    fi

    echo ""
    log "ip_forward:"
    cat /proc/sys/net/ipv4/ip_forward
    exit 0
}

#################################
# УДАЛЕНИЕ ПРАВИЛ
#################################
do_remove() {
    [[ $EUID -eq 0 ]] || die "Запускать нужно от root"

    if [[ ! -f "$CONFIG_FILE" ]]; then
        die "Конфигурация не найдена ($CONFIG_FILE). Нечего удалять."
    fi

    source "$CONFIG_FILE"
    log "Удаляю правила: $ORIGIN_IP_SAVED порты $PORTS_SAVED"

    # Восстанавливаем before.rules из последнего бэкапа
    local latest_backup
    latest_backup=$(ls -t "$BACKUP_DIR"/before.rules.* 2>/dev/null | head -1)
    if [[ -n "$latest_backup" ]]; then
        cp "$latest_backup" /etc/ufw/before.rules
        log "before.rules восстановлен из $latest_backup"
    else
        warn "Бэкап before.rules не найден — чистим правила вручную"
        sed -i '/# NAT-FORWARDER-BEGIN/,/# NAT-FORWARDER-END/d' /etc/ufw/before.rules
    fi

    # Удаляем UFW-правила для портов
    local IFS=','
    read -ra port_list <<< "$PORTS_SAVED"
    for p in "${port_list[@]}"; do
        ufw delete allow "$p/tcp" 2>/dev/null || true
        ufw delete allow "$p/udp" 2>/dev/null || true
    done

    ufw reload
    rm -f "$CONFIG_FILE"
    log_to_file "REMOVED: rules for $ORIGIN_IP_SAVED ports $PORTS_SAVED"
    log "Правила удалены. sysctl-оптимизации оставлены (они безвредны)."
    exit 0
}

#################################
# USAGE
#################################
usage() {
    echo "Использование:"
    echo "  $0                            — интерактивная установка"
    echo "  $0 --ip IP --ports PORTS      — неинтерактивная установка"
    echo "  $0 --status                   — показать текущие правила"
    echo "  $0 --remove                   — удалить все правила"
    echo "  $0 --dry-run --ip IP --ports P — показать что будет сделано"
    echo ""
    echo "Примеры портов: 443 | 443,8443 | 8000:9000 | 443,8000:9000"
    exit 0
}

#################################
# ПАРСИНГ АРГУМЕНТОВ
#################################
DRY_RUN=false
ARG_IP=""
ARG_PORTS=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --status)  show_status ;;
        --remove)  do_remove ;;
        --dry-run) DRY_RUN=true; shift ;;
        --ip)      ARG_IP="$2"; shift 2 ;;
        --ports)   ARG_PORTS="$2"; shift 2 ;;
        --help|-h) usage ;;
        *) die "Неизвестный аргумент: $1. Используйте --help" ;;
    esac
done

[[ $EUID -eq 0 ]] || die "Запускать нужно от root"

. /etc/os-release
if [[ "$ID" != "ubuntu" && "$ID" != "debian" ]]; then
    die "Этот скрипт поддерживает только Ubuntu или Debian: $ID"
fi

#################################
# ASCII-баннер
#################################
echo "==================================================="
echo "     _   _____  ______   ______                    "
echo "    / | / /   |/_  __/  / ____/___  ______      __ "
echo "   /  |/ / /| | / /    / /_  / __ \\/ ___/ | /| / / "
echo "  / /|  / ___ |/ /    / __/ / /_/ / /   | |/ |/ /  "
echo " /_/ |_/_/  |_/_/    /_/    \\____/_/    |__/|__/   "
echo ""
echo "         NAT Forwarder — cascade VPN setup          "
echo "==================================================="
echo ""

#################################
# ВВОД ПАРАМЕТРОВ
#################################
if [[ -n "$ARG_IP" ]]; then
    ORIGIN_IP="$ARG_IP"
else
    read -r -p "IP-адрес зарубежного сервера: " FOREIGN_IP_RAW < /dev/tty
    ORIGIN_IP=$(echo "$FOREIGN_IP_RAW" | tr -d '[:space:]')
fi

validate_ip "$ORIGIN_IP" || die "Некорректный IP-адрес: $ORIGIN_IP"

if [[ -n "$ARG_PORTS" ]]; then
    PORTS="$ARG_PORTS"
else
    read -r -p "Порты (443 или 443,8443 или 8000:9000): " PORT_RAW < /dev/tty
    PORTS=$(echo "$PORT_RAW" | tr -d '[:space:]')
fi

validate_ports "$PORTS" || die "Некорректный формат портов: $PORTS"

LOCAL_IP=$(hostname -I | awk '{print $1}' | tr -d '[:space:]')
[[ -n "$LOCAL_IP" ]] || die "Не удалось определить локальный IP"

#################################
# ПРОВЕРКА ДУБЛИКАТОВ
#################################
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
    if [[ "${ORIGIN_IP_SAVED:-}" == "$ORIGIN_IP" && "${PORTS_SAVED:-}" == "$PORTS" ]]; then
        warn "Правила для $ORIGIN_IP:$PORTS уже установлены."
        read -r -p "Переустановить? (y/N): " confirm < /dev/tty
        [[ "$confirm" =~ ^[yYдД] ]] || { log "Отменено."; exit 0; }
    fi
fi

#################################
# ПРОВЕРКА ДОСТУПНОСТИ
#################################
log "Проверяю доступность $ORIGIN_IP..."
if ping -c 2 -W 3 "$ORIGIN_IP" >/dev/null 2>&1; then
    log "Сервер $ORIGIN_IP доступен"
else
    warn "Сервер $ORIGIN_IP не отвечает на ping (может быть закрыт ICMP — продолжаю)"
fi

#################################
# DRY-RUN
#################################
if $DRY_RUN; then
    echo ""
    log "=== DRY-RUN: что будет сделано ==="
    echo "  Локальный IP:   $LOCAL_IP"
    echo "  Foreign IP:     $ORIGIN_IP"
    echo "  Порты:          $PORTS"
    echo ""
    echo "  1. sysctl: ip_forward=1, BBR, conntrack 2M, буферы"
    echo "  2. UFW before.rules:"
    echo "     PREROUTING  -p tcp/udp --dports $PORTS -j DNAT → $ORIGIN_IP"
    echo "     POSTROUTING -d $ORIGIN_IP -j SNAT → $LOCAL_IP"
    echo "     FORWARD: RELATED,ESTABLISHED + только $ORIGIN_IP:$PORTS"
    echo "  3. UFW allow $PORTS/tcp + $PORTS/udp"
    echo "  4. FORWARD policy: ACCEPT"
    echo ""
    log "Ничего не изменено (dry-run)."
    exit 0
fi

#################################
# UFW
#################################
if ! command -v ufw >/dev/null 2>&1; then
    log "UFW не установлен. Устанавливаю..."
    apt update -qq && apt install -y ufw
fi

if LC_ALL=C ufw status 2>/dev/null | grep -q "Status: active"; then
    log "UFW активен"
else
    warn "UFW выключен. Включаю..."
    ufw allow OpenSSH >/dev/null 2>&1 || true
    ufw --force enable >/dev/null 2>&1
    LC_ALL=C ufw status 2>/dev/null | grep -q "Status: active" || die "Не удалось включить UFW"
    log "UFW включён"
fi

#################################
# SYSCTL
#################################
log "Оптимизация сетевого стека ядра..."
cat <<EOF > /etc/sysctl.d/99-relay-optimization.conf
net.ipv4.ip_forward = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.netfilter.nf_conntrack_max = 2000000
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_mtu_probing = 1
net.ipv4.conf.all.accept_local = 1
net.ipv4.conf.all.route_localnet = 1
net.core.netdev_max_backlog = 250000
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_tw_reuse = 1
EOF
sysctl --system > /dev/null 2>&1

#################################
# БЭКАП before.rules (С ДАТОЙ)
#################################
mkdir -p "$BACKUP_DIR"
BACKUP_NAME="before.rules.$(date '+%Y%m%d-%H%M%S')"
cp /etc/ufw/before.rules "$BACKUP_DIR/$BACKUP_NAME"
log "Бэкап: $BACKUP_DIR/$BACKUP_NAME"

# Чистка старых бэкапов (оставляем 10 последних)
ls -t "$BACKUP_DIR"/before.rules.* 2>/dev/null | tail -n +11 | xargs -r rm -f

#################################
# ГЕНЕРАЦИЯ ПРАВИЛ
#################################
log "Настройка правил перенаправления..."

DPORTS_STR="$PORTS"

cat <<EOF > /tmp/ufw_nat_rules
# NAT-FORWARDER-BEGIN — managed by nat-forwarder, do not edit manually
*nat
:PREROUTING ACCEPT [0:0]
:POSTROUTING ACCEPT [0:0]
-A PREROUTING -p tcp -m multiport --dports $DPORTS_STR -j DNAT --to-destination $ORIGIN_IP
-A PREROUTING -p udp -m multiport --dports $DPORTS_STR -j DNAT --to-destination $ORIGIN_IP
-A POSTROUTING -p tcp -d $ORIGIN_IP -j SNAT --to-source $LOCAL_IP
-A POSTROUTING -p udp -d $ORIGIN_IP -j SNAT --to-source $LOCAL_IP
COMMIT

*filter
:FORWARD ACCEPT [0:0]
:INPUT ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
-A FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT
-A FORWARD -d $ORIGIN_IP -p tcp -m multiport --dports $DPORTS_STR -j ACCEPT
-A FORWARD -d $ORIGIN_IP -p udp -m multiport --dports $DPORTS_STR -j ACCEPT
-A FORWARD -s $ORIGIN_IP -j ACCEPT
COMMIT

*mangle
:FORWARD ACCEPT [0:0]
-A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
COMMIT
# NAT-FORWARDER-END
EOF

# Убираем старые секции
sed -i '/# NAT-FORWARDER-BEGIN/,/# NAT-FORWARDER-END/d' /etc/ufw/before.rules
sed -i '/\*nat/,/COMMIT/d' /etc/ufw/before.rules
sed -i '/\*mangle/,/COMMIT/d' /etc/ufw/before.rules

cat /tmp/ufw_nat_rules /etc/ufw/before.rules > /etc/ufw/before.rules.new
mv /etc/ufw/before.rules.new /etc/ufw/before.rules
rm -f /tmp/ufw_nat_rules

#################################
# ОТКРЫТИЕ ПОРТОВ
#################################
log "Открытие портов в UFW..."
IFS=',' read -ra port_list <<< "$PORTS"
for p in "${port_list[@]}"; do
    ufw allow "$p/tcp" >/dev/null 2>&1
    ufw allow "$p/udp" >/dev/null 2>&1
done

sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw

#################################
# ПРИМЕНЕНИЕ
#################################
log "Перезагрузка UFW..."
ufw reload

#################################
# СОХРАНЕНИЕ КОНФИГА
#################################
cat <<EOF > "$CONFIG_FILE"
# NAT Forwarder config — $(date '+%Y-%m-%d %H:%M:%S')
ORIGIN_IP_SAVED=$ORIGIN_IP
PORTS_SAVED=$PORTS
LOCAL_IP_SAVED=$LOCAL_IP
INSTALLED_AT=$(date '+%Y-%m-%d %H:%M:%S')
EOF

log_to_file "INSTALLED: $ORIGIN_IP ports $PORTS (local: $LOCAL_IP)"

#################################
# ВЕРИФИКАЦИЯ
#################################
echo ""
log "=== Проверка ==="
echo ""

if iptables -t nat -L PREROUTING -n 2>/dev/null | grep -q "$ORIGIN_IP"; then
    log "DNAT → $ORIGIN_IP — ✅"
else
    warn "DNAT правило не найдено — проверьте вручную!"
fi

if iptables -t nat -L POSTROUTING -n 2>/dev/null | grep -q "$LOCAL_IP"; then
    log "SNAT → $LOCAL_IP — ✅"
else
    warn "SNAT правило не найдено — проверьте вручную!"
fi

fwd_ok=$(iptables -L FORWARD -n 2>/dev/null | grep -c "$ORIGIN_IP" || true)
if (( fwd_ok > 0 )); then
    log "FORWARD rules — ✅ ($fwd_ok правил)"
else
    warn "FORWARD правила не найдены!"
fi

ip_fwd=$(cat /proc/sys/net/ipv4/ip_forward)
if [[ "$ip_fwd" == "1" ]]; then
    log "ip_forward = 1 — ✅"
else
    warn "ip_forward = $ip_fwd — должно быть 1!"
fi

echo ""
echo "==================================================="
log "Готово!"
echo "  Foreign IP:  $ORIGIN_IP"
echo "  Порты:       $PORTS"
echo "  Local IP:    $LOCAL_IP"
echo ""
echo "  Управление:"
echo "    $0 --status   — текущие правила"
echo "    $0 --remove   — удалить всё"
echo "==================================================="
