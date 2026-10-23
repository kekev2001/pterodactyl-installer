#!/usr/bin/env bash
#
# ============================================================================
#
#   WiredHosting Panel Installer - starter
#   https://wiredhosting.nl
#
#   Copyright (c) 2026 WiredHosting. Alle rechten voorbehouden.
#   Zie installer.sh voor de volledige copyrightvermelding.
#
# ============================================================================
#
#   Start de webinstaller: je krijgt hier in SSH een link met gratis SSL
#   (via sslip.io + Let's Encrypt). Daar vul je alles in en volg je de
#   voortgang. Liever alles in de terminal? Gebruik --cli.
#
#   Gebruik:
#     bash <(curl -fsSL https://raw.githubusercontent.com/kekev2001/pterodactyl-installer/main/install.sh)
#
#   Opties:
#     --cli         installeren met vragen in de terminal (geen browser)
#     --port N      poort van de webinstaller (standaard 8443)
#     --stop        webinstaller stoppen en opruimen
#     --help        deze hulp
#
# ============================================================================

set -euo pipefail

REPO="kekev2001/pterodactyl-installer"
BRANCH="${WH_BRANCH:-main}"
APP_DIR="/opt/wiredhosting-installer"
STATE_DIR="/var/lib/wiredhosting-installer"
LOG_FILE="${STATE_DIR}/install.log"
WEB_PORT="${WH_PORT:-8443}"
WEB_UNIT="wiredhosting-webinstaller"
INSTALL_UNIT="wiredhosting-install"

RED=$'\e[0;31m'; GREEN=$'\e[0;32m'; YELLOW=$'\e[1;33m'
BLUE=$'\e[0;36m'; BOLD=$'\e[1m'; DIM=$'\e[2m'; NC=$'\e[0m'

info()  { echo -e "${BLUE}[*]${NC} $1"; }
ok()    { echo -e "${GREEN}[+]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
fail()  { echo -e "${RED}[x]${NC} $1" >&2; exit 1; }

banner() {
cat <<'EOF'

 __        __  _               _ _   _           _   _
 \ \      / / (_)_ __ ___  __| | | | | | ___  ___| |_(_)_ __   __ _
  \ \ /\ / /  | | '__/ _ \/ _` | |_| |/ _ \/ __| __| | '_ \ / _` |
   \ V  V /   | | | |  __/ (_| |  _  | (_) \__ \ |_| | | | | (_| |
    \_/\_/    |_|_|  \___|\__,_|_| |_|\___/|___/\__|_|_| |_|\__, |
                                                            |___/
EOF
echo -e "        ${BOLD}Pterodactyl Installer${NC}  |  wiredhosting.nl"
echo -e "   Copyright (c) 2026 WiredHosting. Alle rechten voorbehouden."
echo
}

usage() {
  cat <<'EOF'
Gebruik: bash install.sh [opties]

  (geen optie)  kiezen tussen webinstaller en terminal
  --web         meteen de webinstaller starten
  --cli         installeren met vragen in de terminal (geen browser)
  --port N      poort van de webinstaller (standaard 8443)
  --stop        webinstaller stoppen en opruimen
EOF
}

# ----------------------------------------------------------------------------
#  Hulpjes
# ----------------------------------------------------------------------------
os_family() {
  # shellcheck disable=SC1091
  . /etc/os-release 2>/dev/null || fail "Kan /etc/os-release niet lezen."
  case "${ID:-} ${ID_LIKE:-}" in
    *debian*|*ubuntu*) echo "debian" ;;
    *rhel*|*fedora*|*centos*|*rocky*|*almalinux*) echo "rhel" ;;
    *) echo "unknown" ;;
  esac
}

detect_ip() {
  local ip=""
  ip="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  if ! echo "$ip" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  fi
  echo "$ip"
}

sslip_host() { echo "${1//./-}.sslip.io"; }

have_cert() {
  [ -f "/etc/letsencrypt/live/$1/fullchain.pem" ] \
    && openssl x509 -checkend 86400 -noout -in "/etc/letsencrypt/live/$1/fullchain.pem" >/dev/null 2>&1
}

rand_token() {
  local raw
  raw="$(LC_ALL=C tr -dc 'A-Za-z0-9' < <(head -c 512 /dev/urandom))"
  printf '%s' "${raw:0:32}"
}

# ----------------------------------------------------------------------------
#  Bestanden van de installer ophalen (of de lokale kopie gebruiken)
# ----------------------------------------------------------------------------
fetch_sources() {
  local here=""
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)"
  if [ -n "$here" ] && [ -f "$here/installer.sh" ] && [ -f "$here/web/server.py" ]; then
    SRC="$here"
    return 0
  fi

  info "Installer downloaden (${REPO}@${BRANCH})"
  local tmp
  tmp="$(mktemp -d)"
  curl -fsSL "https://github.com/${REPO}/archive/refs/heads/${BRANCH}.tar.gz" \
    | tar -xz -C "$tmp" --strip-components=1 \
    || fail "Downloaden van de installer is mislukt. Heeft deze server internet?"
  rm -rf "$APP_DIR"
  mkdir -p "$APP_DIR"
  cp -a "$tmp"/. "$APP_DIR"/
  rm -rf "$tmp"
  chmod 700 "$APP_DIR"
  SRC="$APP_DIR"
  ok "Installer staat in $APP_DIR"
}

install_web_deps() {
  local need=0 c
  for c in python3 curl openssl certbot tar; do
    command -v "$c" >/dev/null 2>&1 || need=1
  done
  [ $need -eq 1 ] || return 0

  info "Benodigdheden voor de webinstaller installeren (python3, certbot)"
  case "$OS_FAMILY" in
    debian)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq
      apt-get install -y -qq python3 curl openssl ca-certificates tar >/dev/null
      apt-get install -y -qq certbot >/dev/null || warn "certbot kon niet worden geinstalleerd."
      ;;
    rhel)
      dnf install -y -q python3 curl openssl ca-certificates tar >/dev/null
      dnf install -y -q epel-release >/dev/null 2>&1 || true
      dnf install -y -q certbot >/dev/null 2>&1 || warn "certbot kon niet worden geinstalleerd."
      ;;
  esac
  command -v python3 >/dev/null 2>&1 || fail "python3 is niet beschikbaar. Gebruik 'bash install.sh --cli'."
}

# ----------------------------------------------------------------------------
#  Firewall: poort van de webinstaller (en 80 voor Let's Encrypt) open
# ----------------------------------------------------------------------------
open_firewall() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow 80/tcp >/dev/null
    ufw allow "${WEB_PORT}/tcp" >/dev/null
    ok "UFW: poort 80 en ${WEB_PORT} open"
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    # alleen runtime, verdwijnt vanzelf bij een herstart of reload
    firewall-cmd --add-service=http >/dev/null 2>&1 || true
    firewall-cmd --add-port="${WEB_PORT}/tcp" >/dev/null 2>&1 || true
    ok "firewalld: poort 80 en ${WEB_PORT} tijdelijk open"
  fi
}

# ----------------------------------------------------------------------------
#  SSL voor de webinstaller: Let's Encrypt via sslip.io, anders self-signed
# ----------------------------------------------------------------------------
get_cert() {
  CERT_KIND="selfsigned"
  if [ -n "$WEB_HOST_IP" ]; then
    WEB_HOST="$(sslip_host "$WEB_HOST_IP")"
    if have_cert "$WEB_HOST"; then
      CERT="/etc/letsencrypt/live/${WEB_HOST}/fullchain.pem"
      KEY="/etc/letsencrypt/live/${WEB_HOST}/privkey.pem"
      CERT_KIND="letsencrypt"
      ok "Bestaand certificaat voor ${WEB_HOST} gevonden"
      return 0
    fi
    if command -v certbot >/dev/null 2>&1; then
      info "Gratis SSL certificaat aanvragen voor ${WEB_HOST} (sslip.io + Let's Encrypt)"
      # Bij verlengen moet poort 80 vrij zijn; staat er straks nginx, dan
      # zetten de hooks die heel even stil.
      if certbot certonly --standalone --non-interactive --agree-tos \
           --register-unsafely-without-email -d "$WEB_HOST" \
           --pre-hook "systemctl is-active --quiet nginx && systemctl stop nginx && touch /run/wh-nginx-stopped || true" \
           --post-hook "[ -f /run/wh-nginx-stopped ] && rm -f /run/wh-nginx-stopped && systemctl start nginx || true" \
           > "${STATE_DIR}/certbot.log" 2>&1; then
        CERT="/etc/letsencrypt/live/${WEB_HOST}/fullchain.pem"
        KEY="/etc/letsencrypt/live/${WEB_HOST}/privkey.pem"
        CERT_KIND="letsencrypt"
        echo "$WEB_HOST" > "${STATE_DIR}/installer_cert"
        ok "Certificaat uitgegeven voor ${WEB_HOST}"
        return 0
      fi
      warn "Let's Encrypt lukte niet (details: ${STATE_DIR}/certbot.log)."
      warn "Meestal is poort 80 dicht in de firewall van je provider."
    fi
  else
    WEB_HOST=""
  fi

  info "Tijdelijk self-signed certificaat maken"
  CERT="${STATE_DIR}/selfsigned.crt"
  KEY="${STATE_DIR}/selfsigned.key"
  openssl req -x509 -newkey rsa:2048 -nodes -days 7 -subj "/CN=${WEB_HOST:-wiredhosting-installer}" \
    -keyout "$KEY" -out "$CERT" >/dev/null 2>&1 || fail "Kan geen certificaat maken."
  chmod 600 "$KEY"
  warn "Je browser geeft straks een waarschuwing, dat is bij self-signed normaal."
}

# ----------------------------------------------------------------------------
#  Opruimen: firewallregel weg en het certificaat van de webinstaller weg,
#  tenzij het panel of de node het gebruikt
# ----------------------------------------------------------------------------
cleanup() {
  local port host
  port="$(cat "${STATE_DIR}/port" 2>/dev/null || echo "$WEB_PORT")"
  if command -v ufw >/dev/null 2>&1; then
    ufw delete allow "${port}/tcp" >/dev/null 2>&1 || true
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --remove-port="${port}/tcp" >/dev/null 2>&1 || true
  fi

  host="$(cat "${STATE_DIR}/installer_cert" 2>/dev/null || true)"
  if [ -n "$host" ]; then
    if grep -qsxF "$host" "${STATE_DIR}/certs_in_use" \
       || grep -rqsF "/etc/letsencrypt/live/${host}/" /etc/nginx /etc/pterodactyl/config.yml; then
      : # in gebruik door het panel of de node, laten staan
    elif command -v certbot >/dev/null 2>&1; then
      certbot delete --cert-name "$host" --non-interactive >/dev/null 2>&1 || true
    fi
  fi
  rm -f "${STATE_DIR}/token" "${STATE_DIR}/installer_cert" "${STATE_DIR}/port" \
        "${STATE_DIR}/selfsigned.crt" "${STATE_DIR}/selfsigned.key"
}

stop_web() {
  systemctl stop "$WEB_UNIT" >/dev/null 2>&1 || true
  pkill -f "web/server.py --port" >/dev/null 2>&1 || true
}

# ----------------------------------------------------------------------------
#  Webinstaller starten
# ----------------------------------------------------------------------------
start_web() {
  local token
  token="$(rand_token)"
  ( umask 077; printf '%s' "$token" > "${STATE_DIR}/token" )
  echo "$WEB_PORT" > "${STATE_DIR}/port"

  local -a cmd=(python3 "${SRC}/web/server.py"
    --port "$WEB_PORT" --cert "$CERT" --key "$KEY"
    --token-file "${STATE_DIR}/token" --app-dir "$SRC" --state-dir "$STATE_DIR")

  systemctl reset-failed "$WEB_UNIT" >/dev/null 2>&1 || true
  if command -v systemd-run >/dev/null 2>&1 \
     && systemd-run --unit="$WEB_UNIT" --collect --quiet \
          --setenv=PYTHONUNBUFFERED=1 "${cmd[@]}" >/dev/null 2>&1; then
    :
  else
    nohup setsid "${cmd[@]}" > "${STATE_DIR}/web.log" 2>&1 < /dev/null &
  fi

  local i
  for i in $(seq 1 30); do
    if curl -fsk --max-time 2 "https://127.0.0.1:${WEB_PORT}/healthz" >/dev/null 2>&1; then
      WEB_TOKEN="$token"
      return 0
    fi
    sleep 0.5
  done
  journalctl -u "$WEB_UNIT" -n 20 --no-pager 2>/dev/null || cat "${STATE_DIR}/web.log" 2>/dev/null || true
  fail "De webinstaller start niet. Probeer 'bash install.sh --cli'."
}

print_link() {
  local url host="${WEB_HOST:-$WEB_HOST_IP}"
  url="https://${host}:${WEB_PORT}/?t=${WEB_TOKEN}"
  echo
  echo -e "${GREEN}${BOLD}  ================================================================${NC}"
  echo -e "${GREEN}${BOLD}   De webinstaller staat klaar${NC}"
  echo -e "${GREEN}${BOLD}  ================================================================${NC}"
  echo
  echo -e "   Open deze link in je browser:"
  echo
  echo -e "   ${BOLD}${BLUE}${url}${NC}"
  echo
  if [ "$CERT_KIND" = "letsencrypt" ]; then
    echo -e "   ${GREEN}Beveiligd met een gratis Let's Encrypt certificaat via sslip.io.${NC}"
  else
    echo -e "   ${YELLOW}Self-signed certificaat: klik in je browser op 'Geavanceerd' > 'Doorgaan'.${NC}"
  fi
  echo -e "   ${DIM}Deel deze link met niemand, iedereen met de link kan installeren.${NC}"
  echo -e "   ${DIM}Werkt hij niet? Zet poort ${WEB_PORT} (en 80) open in de firewall van je provider.${NC}"
  echo
}

# ----------------------------------------------------------------------------
#  Voortgang hier in SSH meekijken
# ----------------------------------------------------------------------------
follow_progress() {
  trap 'echo; info "Je kijkt niet meer mee. De installer draait gewoon door in de browser."; exit 0' INT

  if [ ! -f "$LOG_FILE" ]; then
    echo -e "   Wachten tot je de installatie start in de browser...  ${DIM}(Ctrl+C sluit alleen deze weergave)${NC}"
    while [ ! -f "$LOG_FILE" ]; do
      if ! curl -fsk --max-time 2 "https://127.0.0.1:${WEB_PORT}/healthz" >/dev/null 2>&1; then
        echo
        info "De webinstaller is gestopt."
        return 0
      fi
      sleep 2
    done
  fi

  echo
  info "Installatie gestart, live voortgang:"
  local line n total label tail_pid
  exec 3< <(tail -n +1 -F "$LOG_FILE" 2>/dev/null)
  tail_pid=$!
  while IFS= read -r line <&3; do
    case "$line" in
      "@@STEP|"*)
        IFS='|' read -r _ n total label <<< "$line"
        echo -e "\n${BOLD}${BLUE}  [${n}/${total}]${NC} ${BOLD}${label}${NC}"
        ;;
      "@@FAIL|"*)
        echo -e "\n${RED}${BOLD}  Installatie mislukt:${NC} ${line#@@FAIL|}"
        ;;
      "@@DONE"*)
        echo -e "\n${GREEN}${BOLD}  Installatie voltooid!${NC} De gegevens staan in de browser en in /root/wiredhosting-panel.txt"
        ;;
      "@@EXIT|"*)
        break
        ;;
      "@@"*) ;;
      *) echo "      $line" ;;
    esac
  done
  kill "$tail_pid" >/dev/null 2>&1 || true
  echo
  info "De webinstaller sluit vanzelf na een uur, of klik in de browser op 'Afsluiten'."
  info "Nu meteen stoppen: bash ${SRC}/install.sh --stop"
}

# ----------------------------------------------------------------------------
#  Main
# ----------------------------------------------------------------------------
MODE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --cli)     MODE="cli" ;;
    --web)     MODE="web" ;;
    --port)    WEB_PORT="${2:-}"; shift ;;
    --stop)    MODE="stop" ;;
    --cleanup) MODE="cleanup" ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
  shift
done

[ "$(id -u)" -eq 0 ] || fail "Draai dit script als root (sudo -i)."
echo "$WEB_PORT" | grep -qE '^[0-9]{2,5}$' || fail "Ongeldige poort: $WEB_PORT"
mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"

case "$MODE" in
  cleanup)
    cleanup
    exit 0
    ;;
  stop)
    stop_web
    cleanup
    ok "Webinstaller gestopt en opgeruimd."
    exit 0
    ;;
esac

banner
OS_FAMILY="$(os_family)"
[ "$OS_FAMILY" != "unknown" ] || fail "Niet ondersteund OS. Gebruik Ubuntu, Debian of RHEL/Rocky/Alma."
command -v curl >/dev/null 2>&1 || {
  if [ "$OS_FAMILY" = "debian" ]; then apt-get update -qq && apt-get install -y -qq curl >/dev/null
  else dnf install -y -q curl >/dev/null; fi
}

if [ -z "$MODE" ]; then
  echo -e "${BOLD}Hoe wil je installeren?${NC}"
  echo "  1) Via de webinstaller in je browser   (aanbevolen, met voortgang en SSL)"
  echo "  2) Hier in de terminal"
  read -rp "  Keuze [1]: " c
  case "${c:-1}" in
    2) MODE="cli" ;;
    *) MODE="web" ;;
  esac
fi

fetch_sources

if [ "$MODE" = "cli" ]; then
  exec bash "${SRC}/installer.sh"
fi

install_web_deps

# Loopt er nog een installatie? Dan alleen de webinstaller opnieuw starten,
# en het oude log van een vorige (afgeronde) poging opzij zetten.
if ! systemctl is-active --quiet "$INSTALL_UNIT" 2>/dev/null && [ -f "$LOG_FILE" ]; then
  mv -f "$LOG_FILE" "${LOG_FILE}.prev"
fi

stop_web
info "Publiek IP opzoeken"
WEB_HOST_IP="$(detect_ip)"
[ -n "$WEB_HOST_IP" ] && ok "Publiek IP: ${WEB_HOST_IP}" || warn "Kon het publieke IP niet bepalen."

open_firewall
get_cert
start_web
print_link
follow_progress
