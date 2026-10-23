#!/usr/bin/env bash
#
# ============================================================================
#
#   WiredHosting Panel Installer
#   https://wiredhosting.nl
#
#   Copyright (c) 2026 WiredHosting. Alle rechten voorbehouden.
#   All rights reserved.
#
#   Dit script is eigendom van WiredHosting en wordt door WiredHosting
#   onderhouden. Het is uitsluitend bedoeld voor gebruik op systemen van
#   WiredHosting en haar klanten.
#
#   Zonder voorafgaande schriftelijke toestemming van WiredHosting is het
#   niet toegestaan dit script of delen daarvan te kopieren, te verspreiden,
#   te wijzigen, te herpubliceren, door te verkopen, of op te nemen in een
#   ander werk, al dan niet gewijzigd en al dan niet onder een andere naam.
#   Deze copyrightvermelding mag niet worden verwijderd of aangepast.
#
#   Vragen of toestemming: info@wiredhosting.nl
#
#   Let op: Pterodactyl Panel en Wings zelf zijn software van derden en
#   vallen onder hun eigen licentie (MIT). Dit copyright geldt alleen voor
#   dit installatiescript, niet voor de software die het installeert.
#
# ============================================================================
#
#   Installeert Pterodactyl op een schone server. Je kiest zelf wat:
#   panel + node, alleen het panel, of alleen een node (Wings).
#   Je kiest zelf de versie: de nieuwste 1.x (stabiel, standaard), de
#   2.0 open beta, of een eigen tag.
#
#   Na de installatie kan het script de node zelf aanmelden bij het panel
#   (locatie, node, Wings-config, allocaties, Wings starten) en de database
#   host in het panel zetten. Bij een los panel elders gaat dat via een
#   Application API key.
#
#   Extra: optie 4 werkt alleen PHP bij op een bestaande server. Bedoeld
#   voor de PHP2Shell patch van 21-10-2026 (CVE-2026-109618 / 109619).
#
#   PHP: 1.x krijgt 8.3, 2.0 krijgt 8.4. Na installatie controleert het
#   script of de PHP versie de PHP2Shell fix bevat.
#
#   Ondersteunde besturingssystemen (volgt de officiele Pterodactyl docs):
#     Ubuntu 22.04 / 24.04 / 26.04
#     Debian 11 / 12 / 13
#     RHEL / Rocky Linux / AlmaLinux 8 / 9
#   2.0 is officieel alleen getest op Ubuntu 22.04+ en Debian 12+.
#
#   Gratis SSL zonder eigen domein: kies sslip.io, dan wordt het panel
#   bereikbaar op https://<ip-met-streepjes>.sslip.io met Let's Encrypt.
#
#   Gebruik (webinstaller, aanbevolen):
#     bash <(curl -fsSL https://raw.githubusercontent.com/kekev2001/pterodactyl-installer/main/install.sh)
#
#   Direct in de terminal:
#     bash installer.sh                 vragen in de terminal
#     bash installer.sh --config f.env  niet-interactief (gebruikt de webinstaller)
#     bash installer.sh --check  --config f.env   alleen de config controleren
#     bash installer.sh --info          servergegevens voor de webinstaller
#
# ============================================================================

set -euo pipefail

# ----------------------------------------------------------------------------
#  Instellingen
# ----------------------------------------------------------------------------
PHP_VERSION_V1="8.3"     # Panel 1.x ondersteunt officieel 8.2 en 8.3
PHP_VERSION_V2="8.4"     # Panel 2.0 ondersteunt officieel 8.3 en 8.4
PHP_VERSION="$PHP_VERSION_V1"
PANEL_DIR="/var/www/pterodactyl"
CRED_FILE="/root/wiredhosting-panel.txt"
DEFAULT_TZ="Europe/Amsterdam"
COMPANY="WiredHosting"
COPYRIGHT_YEAR="2026"
COPYRIGHT_OWNER="WiredHosting"
COPYRIGHT_CONTACT="info@wiredhosting.nl"
DOCS_URL_V1="https://docs.pterodactyl.io/v1"
DOCS_URL_V2="https://docs.pterodactyl.io/v2"
DOCS_URL="$DOCS_URL_V1"
INSTALLER_CMD="bash <(curl -fsSL https://raw.githubusercontent.com/kekev2001/pterodactyl-installer/main/install.sh)"

# Standaardwaarden die de klant kan aanpassen
DEFAULT_DB_NAME="panel"
DEFAULT_DB_USER="pterodactyl"
DEFAULT_DBHOST_NAME="nl-db-1"
DEFAULT_DBADMIN_USER="pteroadmin"
DEFAULT_NODE_NAME="node1"
DEFAULT_LOCATION_SHORT="nl1"
DEFAULT_DAEMON_PORT="8080"
DEFAULT_SFTP_PORT="2022"

# Niet-interactieve modus (webinstaller): config uit een bestand, en
# @@-regels in de uitvoer zodat de webinstaller de voortgang kan tonen.
CONFIG_FILE=""
RUN_MODE="interactive"   # interactive | config | check | info
MACHINE=0
STEP_NO=0
STEP_TOTAL=0

# Fallback versies als de GitHub API niet bereikbaar is
FALLBACK_PANEL_V1_VERSION="v1.15.1"
FALLBACK_PANEL_V2_VERSION="v2.0.0-beta.2"
FALLBACK_WINGS_VERSION="v1.13.3"

# Eerste PHP release per reeks met de PHP2Shell fix (21-10-2026)
php_patched_min() {
  case "$1" in
    8.2) echo "8.2.35" ;;
    8.3) echo "8.3.36" ;;
    8.4) echo "8.4.27" ;;
    8.5) echo "8.5.12" ;;
    *)   echo "" ;;
  esac
}

RED=$'\e[0;31m'; GREEN=$'\e[0;32m'; YELLOW=$'\e[1;33m'
BLUE=$'\e[0;36m'; BOLD=$'\e[1m'; NC=$'\e[0m'

info()  { echo -e "${BLUE}[*]${NC} $1"; }
ok()    { echo -e "${GREEN}[+]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
fail()  {
  echo -e "${RED}[x]${NC} $1" >&2
  if [ "$MACHINE" -eq 1 ]; then echo "@@FAIL|$1"; FAIL_SENT=1; fi
  exit 1
}

# Machineregel voor de webinstaller (alleen in --config modus)
mark() { [ "$MACHINE" -eq 1 ] && echo "@@$1" || true; }

# Volgende stap van de installatie, voor de voortgangsbalk
step() {
  STEP_NO=$((STEP_NO + 1))
  echo
  echo -e "${BOLD}==> [${STEP_NO}/${STEP_TOTAL}] $1${NC}"
  mark "STEP|${STEP_NO}|${STEP_TOTAL}|$1"
}

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
echo -e "   Copyright (c) ${COPYRIGHT_YEAR} ${COPYRIGHT_OWNER}. Alle rechten voorbehouden."
echo -e "   Eigendom van en onderhouden door ${COPYRIGHT_OWNER}. Niet overnemen of"
echo -e "   verspreiden zonder schriftelijke toestemming (${COPYRIGHT_CONTACT})."
echo
}

rand_pass() {
  # geen 'head' aan het eind van een pipe: dat geeft SIGPIPE onder pipefail
  local raw
  raw="$(LC_ALL=C tr -dc 'A-Za-z0-9' < <(head -c 512 /dev/urandom))"
  printf '%s' "${raw:0:24}"
}

yesno() {
  # yesno "vraag" "j|n"  -> zet antwoord in $REPLY_BOOL (1/0)
  local prompt="$1" def="$2" in
  read -rp "$prompt (j/n) [$def]: " in
  in="$(echo "${in:-$def}" | tr '[:upper:]' '[:lower:]')"
  [[ "$in" == "j" || "$in" == "y" ]] && REPLY_BOOL=1 || REPLY_BOOL=0
}

# MariaDB 11 noemt de client 'mariadb', oudere versies 'mysql'
dbcli() {
  if command -v mariadb >/dev/null 2>&1; then mariadb "$@"; else mysql "$@"; fi
}

# Pakketten installeren, onafhankelijk van de distro
pkg_install() {
  if [ "$OS_FAMILY" = "debian" ]; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" >/dev/null
  else
    dnf install -y -q "$@" >/dev/null
  fi
}

pkg_update() {
  if [ "$OS_FAMILY" = "debian" ]; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
  else
    dnf makecache -q >/dev/null 2>&1 || true
  fi
}

# Alle release tags van een pterodactyl repo ophalen (nieuwste eerst)
repo_tags() {
  curl -fsSL --max-time 20 \
    "https://api.github.com/repos/pterodactyl/$1/releases?per_page=100" 2>/dev/null \
    | grep -oP '"tag_name":\s*"\K[^"]+' || true
}

# Versie bepalen op basis van het gekozen kanaal
#   resolve_version <repo> <kanaal> <fallback>
#   kanaal: v1 | v2 | een exacte tag
#   v1 = nieuwste stabiele 1.x (geen beta/rc)
#   v2 = nieuwste 2.x, inclusief pre-releases zolang 2.0 in beta is
resolve_version() {
  local repo="$1" channel="$2" fallback="$3" tag=""

  case "$channel" in
    v1)
      tag="$(repo_tags "$repo" | grep -m1 -E '^v?1\.[0-9]+\.[0-9]+$' || true)"
      ;;
    v2)
      tag="$(repo_tags "$repo" | grep -m1 -E '^v?2\.[0-9]+\.[0-9]+' || true)"
      ;;
    *)
      tag="$channel"
      ;;
  esac

  [ -n "$tag" ] || tag="$fallback"
  echo "$tag"
}

want_panel() { [ "$INSTALL_MODE" = "panel" ] || [ "$INSTALL_MODE" = "both" ]; }
want_node()  { [ "$INSTALL_MODE" = "node" ]  || [ "$INSTALL_MODE" = "both" ]; }

# nginx >= 1.25.1 wil 'http2 on;', ouder wil 'listen 443 ssl http2;'
nginx_listen_ssl() {
  local v major minor patch
  v="$(nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)"
  major="${v%%.*}"; minor="$(echo "$v" | cut -d. -f2)"; patch="$(echo "$v" | cut -d. -f3)"
  if [ -z "$v" ]; then
    # onbekend: de oude syntax werkt op alles tot 1.25
    NGINX_LISTEN="    listen 443 ssl http2;\n    listen [::]:443 ssl http2;"
    return
  fi
  if [ "$major" -gt 1 ] || { [ "$major" -eq 1 ] && [ "$minor" -gt 25 ]; } \
     || { [ "$major" -eq 1 ] && [ "$minor" -eq 25 ] && [ "$patch" -ge 1 ]; }; then
    NGINX_LISTEN="    listen 443 ssl;\n    listen [::]:443 ssl;\n    http2 on;"
  else
    NGINX_LISTEN="    listen 443 ssl http2;\n    listen [::]:443 ssl http2;"
  fi
}

# Publiek IP van deze server bepalen (voor een standaardwaarde)
detect_ip() {
  local ip=""
  ip="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  if ! echo "$ip" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  fi
  echo "$ip"
}

# Controleren of een download-URL bestaat
url_exists() { curl -fsIL --max-time 20 -o /dev/null "$1" 2>/dev/null; }

# Is dit een IPv4-adres? Let's Encrypt geeft geen certificaat op een kaal IP,
# dus dan slaan we SSL over en draait het panel op http.
is_ip() {
  echo "$1" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'
}

# Geldige hostnaam (domein) volgens de gebruikelijke regels
is_domain() {
  echo "$1" | grep -Pq '^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)+$'
}

# Gratis hostnaam via sslip.io: 203.0.113.10 -> 203-0-113-10.sslip.io.
# sslip.io wijst die naam terug naar het IP, dus Let's Encrypt kan hem
# gewoon valideren en je krijgt een echt certificaat zonder eigen domein.
sslip_host() { echo "${1//./-}.sslip.io"; }

# Let's Encrypt mag zonder e-mailadres, dan krijg je alleen geen verloopmails
certbot_email_args() {
  if [ -n "${ADMIN_EMAIL:-}" ]; then echo "-m ${ADMIN_EMAIL}"; else echo "--register-unsafely-without-email"; fi
}

# Onthouden welke certificaten het panel/de node gebruikt, zodat de
# webinstaller die bij het opruimen laat staan
note_cert_in_use() {
  mkdir -p /var/lib/wiredhosting-installer
  echo "$1" >> /var/lib/wiredhosting-installer/certs_in_use
}

# Staat er al een (nog geldig) certificaat voor deze naam?
have_cert() {
  [ -f "/etc/letsencrypt/live/$1/fullchain.pem" ] \
    && openssl x509 -checkend 86400 -noout -in "/etc/letsencrypt/live/$1/fullchain.pem" >/dev/null 2>&1
}

# Invoer controleren. Deze waarden komen in SQL, PHP en JSON terecht, dus
# alleen veilige tekens toestaan.
valid_dbname()  { echo "$1" | grep -qE '^[A-Za-z0-9_]{1,64}$'; }
valid_dbuser()  { echo "$1" | grep -qE '^[A-Za-z0-9_]{1,32}$'; }
valid_secret()  { echo "$1" | grep -qE '^[A-Za-z0-9_.@#%^*+=!,:-]{8,64}$'; }
valid_name()    { echo "$1" | grep -qE '^[A-Za-z0-9 _.-]{1,100}$'; }
valid_text()    { echo "$1" | grep -qE '^[A-Za-z0-9 _.,()&/-]{1,191}$'; }
valid_short()   { echo "$1" | grep -qE '^[A-Za-z0-9_.-]{1,60}$'; }
valid_user()    { echo "$1" | grep -qE '^[a-z0-9_.-]{1,191}$'; }
valid_email()   { echo "$1" | grep -qE '^[^@[:space:]"'"'"'\\]+@[^@[:space:]"'"'"'\\]+\.[A-Za-z]{2,}$'; }
valid_port()    { echo "$1" | grep -qE '^[0-9]{1,5}$' && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
valid_ports()   { echo "$1" | grep -qE '^[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*$'; }
valid_dbhostpattern() { echo "$1" | grep -qE '^[A-Za-z0-9.%:_-]{1,255}$'; }

# SELinux actief (enforcing of permissive)?
selinux_active() {
  command -v getenforce >/dev/null 2>&1 && [ "$(getenforce 2>/dev/null)" != "Disabled" ]
}

# ----------------------------------------------------------------------------
#  PHP2Shell check (CVE-2026-109618 / CVE-2026-109619)
#   check_php_patched <php binary>
#   zet PHP_UNPATCHED=1 als de geinstalleerde versie te oud is
# ----------------------------------------------------------------------------
check_php_patched() {
  local bin="$1" cur series min
  command -v "$bin" >/dev/null 2>&1 || { warn "Geen $bin gevonden, kan patchstatus niet controleren."; return 0; }

  cur="$("$bin" -r 'echo PHP_VERSION;' 2>/dev/null || true)"
  [ -n "$cur" ] || { warn "Kan de PHP versie van $bin niet uitlezen."; return 0; }
  series="$(echo "$cur" | grep -oE '^[0-9]+\.[0-9]+')"
  min="$(php_patched_min "$series")"

  if [ -z "$min" ]; then
    warn "PHP $cur ($bin): PHP2Shell wordt alleen gefixt in 8.2.35 / 8.3.36 / 8.4.27 / 8.5.12."
    warn "Deze reeks krijgt geen patch meer. Upgrade naar 8.3 of 8.4."
    PHP_UNPATCHED=1
    return 0
  fi

  if dpkg_compare "$cur" "$min"; then
    ok "PHP $cur bevat de PHP2Shell fix (>= $min)"
  else
    echo
    warn "PHP $cur is KWETSBAAR voor PHP2Shell (CVE-2026-109618 / CVE-2026-109619)."
    warn "De fix zit in PHP $min of nieuwer. De repository heeft die blijkbaar nog niet."
    warn "Draai later opnieuw: ${INSTALLER_CMD}  en kies 'Alleen PHP updaten'."
    echo
    PHP_UNPATCHED=1
  fi
}

# dpkg_compare <a> <b>  -> waar als a >= b (werkt ook zonder dpkg)
dpkg_compare() {
  if command -v dpkg >/dev/null 2>&1; then
    dpkg --compare-versions "$1" ge "$2"
  else
    [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]
  fi
}

# ----------------------------------------------------------------------------
#  Alleen PHP bijwerken op een bestaande server (optie 4)
# ----------------------------------------------------------------------------
patch_php() {
  local pkgs svc v found=0
  echo
  info "PHP bijwerken voor PHP2Shell (CVE-2026-109618 / CVE-2026-109619)"

  if [ "$OS_FAMILY" = "debian" ]; then
    export DEBIAN_FRONTEND=noninteractive
    pkgs="$(dpkg-query -W -f='${binary:Package}\n' 'php*' 2>/dev/null | tr '\n' ' ' || true)"
    [ -n "${pkgs// /}" ] || fail "Geen PHP pakketten gevonden op deze server. Niets te patchen."
    apt-get update -qq
    # shellcheck disable=SC2086
    apt-get install -y -qq --only-upgrade $pkgs >/dev/null
  else
    rpm -qa 'php*' | grep -q . || fail "Geen PHP pakketten gevonden op deze server. Niets te patchen."
    dnf upgrade -y -q 'php*' >/dev/null
  fi
  ok "PHP pakketten bijgewerkt"

  info "PHP-FPM herstarten"
  for svc in $(systemctl list-units --type=service --all --no-legend 'php*-fpm.service' 'php-fpm.service' 2>/dev/null | awk '{print $1}' | sort -u); do
    systemctl restart "$svc" 2>/dev/null && ok "$svc herstart" || warn "$svc kon niet herstarten"
  done
  for svc in apache2 httpd; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
      systemctl restart "$svc" && ok "$svc herstart"
    fi
  done

  echo
  info "Patchstatus per geinstalleerde PHP"
  for v in 8.2 8.3 8.4 8.5; do
    if command -v "php$v" >/dev/null 2>&1; then check_php_patched "php$v"; found=1; fi
  done
  if [ $found -eq 0 ] && command -v php >/dev/null 2>&1; then
    check_php_patched php
  fi
  for v in 7.4 8.0 8.1; do
    if command -v "php$v" >/dev/null 2>&1; then
      warn "PHP $v staat nog op deze server. Die reeks is EOL en krijgt GEEN PHP2Shell fix."
      warn "Verwijder hem of zorg dat er geen webverkeer meer naartoe gaat."
    fi
  done

  echo
  if [ "${PHP_UNPATCHED:-0}" -eq 1 ]; then
    warn "Niet alles is gepatcht. Zie de meldingen hierboven."
  else
    echo -e "${GREEN}${BOLD}  PHP is bijgewerkt en gepatcht.${NC}"
  fi
  echo
}

# ----------------------------------------------------------------------------
#  Checks vooraf: OS herkennen en de distro-afhankelijke paden zetten
# ----------------------------------------------------------------------------
preflight() {
  [ "$(id -u)" -eq 0 ] || fail "Draai dit script als root (sudo -i)."

  [ -f /etc/os-release ] || fail "Kan /etc/os-release niet lezen."
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="$ID"
  OS_CODENAME="${VERSION_CODENAME:-}"
  OS_VERSION_ID="${VERSION_ID:-}"
  OS_MAJOR="${OS_VERSION_ID%%.*}"

  case "$OS_ID" in
    ubuntu)
      OS_FAMILY="debian"
      case "$OS_VERSION_ID" in
        22.04|24.04|26.04) ;;
        *) warn "Ubuntu $OS_VERSION_ID staat niet in de Pterodactyl docs. Doorgaan op eigen risico." ;;
      esac
      ;;
    debian)
      OS_FAMILY="debian"
      case "$OS_VERSION_ID" in
        11|12|13) ;;
        *) warn "Debian $OS_VERSION_ID staat niet in de Pterodactyl docs. Doorgaan op eigen risico." ;;
      esac
      ;;
    rhel|rocky|almalinux|centos|ol)
      OS_FAMILY="rhel"
      case "$OS_MAJOR" in
        8|9) ;;
        *) warn "$NAME $OS_VERSION_ID staat niet in de Pterodactyl docs (wel 8 en 9). Doorgaan op eigen risico." ;;
      esac
      command -v dnf >/dev/null 2>&1 || fail "dnf niet gevonden. Dit script ondersteunt alleen dnf-gebaseerde Enterprise Linux."
      ;;
    *)
      fail "Niet ondersteund OS: $PRETTY_NAME. Gebruik Ubuntu 22.04/24.04/26.04, Debian 11/12/13 of RHEL/Rocky/Alma 8/9."
      ;;
  esac

  # Distro-afhankelijke paden en namen
  if [ "$OS_FAMILY" = "debian" ]; then
    WEB_USER="www-data"
    REDIS_PKG="redis-server"
    REDIS_SVC="redis-server"
    CRON_PKG="cron"
    NGINX_CONF="/etc/nginx/sites-available/pterodactyl.conf"
    MYSQL_CONF_DIR="/etc/mysql/conf.d"
  else
    WEB_USER="nginx"
    REDIS_PKG="redis"
    REDIS_SVC="redis"
    CRON_PKG="cronie"
    NGINX_CONF="/etc/nginx/conf.d/pterodactyl.conf"
    MYSQL_CONF_DIR="/etc/my.cnf.d"
  fi

  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64)  WINGS_ARCH="amd64" ;;
    aarch64) WINGS_ARCH="arm64" ;;
    *) fail "Niet ondersteunde architectuur: $ARCH" ;;
  esac

  ok "$PRETTY_NAME ($ARCH) gedetecteerd."
  if [ "$OS_FAMILY" = "rhel" ] && selinux_active; then
    info "SELinux staat op $(getenforce). Het script zet de benodigde booleans en contexts."
  fi
}

# PHP-paden hangen af van distro en versie, dus pas na de versiekeuze
set_php_paths() {
  if [ "$OS_FAMILY" = "debian" ]; then
    PHP_FPM_SVC="php${PHP_VERSION}-fpm"
    PHP_FPM_SOCK="/run/php/php${PHP_VERSION}-fpm.sock"
    PHP_BIN="php${PHP_VERSION}"
  else
    PHP_FPM_SVC="php-fpm"
    PHP_FPM_SOCK="/var/run/php-fpm/pterodactyl.sock"
    PHP_BIN="php"
  fi
}

# ----------------------------------------------------------------------------
#  Vragen in de terminal
# ----------------------------------------------------------------------------

# ask_default VAR "vraag" "standaard"
ask_default() {
  local __var="$1" __prompt="$2" __def="$3" __in
  read -rp "$__prompt${__def:+ [$__def]}: " __in
  printf -v "$__var" '%s' "${__in:-$__def}"
}

# ask_valid VAR "vraag" "standaard" check "foutmelding"  -> blijft vragen
ask_valid() {
  local __var="$1" __prompt="$2" __def="$3" __check="$4" __msg="$5"
  while :; do
    ask_default "$__var" "$__prompt" "$__def"
    "$__check" "${!__var}" && return 0
    warn "$__msg"
  done
}

# Versie tag normaliseren: 1.11.11 -> v1.11.11
norm_tag() {
  if echo "$1" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+'; then echo "v$1"; else echo "$1"; fi
}

ask() {
  local c pub_ip sslip
  pub_ip="$(detect_ip)"
  PUBLIC_IP="$pub_ip"
  sslip="$(sslip_host "$pub_ip")"

  echo
  echo -e "${BOLD}Wat wil je op deze server doen?${NC}"
  echo "  1) Panel + node        alles op een machine"
  echo "  2) Alleen het panel    nodes draaien elders"
  echo "  3) Alleen een node     Wings, meldt zich aan bij een bestaand panel"
  echo "  4) Alleen PHP updaten  bestaande server patchen (PHP2Shell, 21-10-2026)"
  read -rp "  Keuze [1]: " c
  case "${c:-1}" in
    2) INSTALL_MODE="panel" ;;
    3) INSTALL_MODE="node"  ;;
    4) INSTALL_MODE="phpfix"; return 0 ;;
    *) INSTALL_MODE="both"  ;;
  esac

  if want_panel && [ -d "$PANEL_DIR" ] && [ -f "$PANEL_DIR/.env" ]; then
    fail "Er staat al een panel in $PANEL_DIR. Verwijder dat eerst of gebruik een schone server."
  fi
  if want_node && [ -f /usr/local/bin/wings ]; then
    warn "Er staat al een Wings in /usr/local/bin/wings, die wordt overschreven."
  fi

  echo
  echo -e "${BOLD}Configuratie${NC}  (Enter = de waarde tussen [haakjes])"
  echo "-----------------------------------------------"

  if want_panel; then
    echo
    echo -e "${BOLD}Op welk adres moet het panel bereikbaar zijn?${NC}"
    echo "  1) Gratis adres met SSL   https://${sslip}"
    echo "                            via sslip.io, je hebt geen eigen domein nodig"
    echo "  2) Eigen domein           bv. panel.wiredhosting.nl (A-record naar ${pub_ip})"
    echo "  3) Alleen IP, zonder SSL  http://${pub_ip}"
    read -rp "  Keuze [1]: " c
    case "${c:-1}" in
      2) PANEL_DOMAIN_MODE="domain"
         while :; do
           ask_default FQDN "Panel domein" ""
           if is_ip "$FQDN"; then
             warn "Dat is een IP-adres. Kies optie 1 (sslip.io) als je SSL wilt zonder domein."
           elif is_domain "$FQDN"; then
             break
           else
             warn "Dat lijkt geen geldig domein."
           fi
         done
         yesno "Let's Encrypt SSL aanvragen voor $FQDN?" "j"; USE_SSL=$REPLY_BOOL
         ;;
      3) PANEL_DOMAIN_MODE="ip" ;;
      *) PANEL_DOMAIN_MODE="sslip" ;;
    esac

    echo
    echo -e "${BOLD}Admin account${NC}"
    ask_valid ADMIN_EMAIL "E-mailadres (ook voor Let's Encrypt)" "" valid_email "Vul een geldig e-mailadres in."
    ask_valid ADMIN_USER "Gebruikersnaam" "admin" valid_user "Alleen kleine letters, cijfers, punt, streep en underscore."
    ask_default ADMIN_FIRST "Voornaam" "Wired"
    ask_default ADMIN_LAST "Achternaam" "Hosting"
    while :; do
      read -rsp "Wachtwoord (leeg = automatisch genereren): " ADMIN_PASS; echo
      [ -z "$ADMIN_PASS" ] || [ "${#ADMIN_PASS}" -ge 8 ] && break
      warn "Gebruik minimaal 8 tekens."
    done
    ask_default TIMEZONE "Tijdzone" "$DEFAULT_TZ"

    echo
    echo -e "${BOLD}Database van het panel${NC}"
    ask_valid DB_NAME "Naam van de database" "$DEFAULT_DB_NAME" valid_dbname "Alleen letters, cijfers en _ (max 64 tekens)."
    ask_valid DB_USER "Database gebruiker" "$DEFAULT_DB_USER" valid_dbuser "Alleen letters, cijfers en _ (max 32 tekens)."
    DB_PASS=""
  fi

  if want_node && ! want_panel; then
    echo
    echo -e "${BOLD}Adres van deze node${NC}"
    echo "Draait je panel op https (aanbevolen), dan moet de node ook SSL hebben,"
    echo "anders kan de browser niet met de console van de servers praten."
    echo "  1) Gratis adres met SSL   ${sslip}  (sslip.io, geen domein nodig)"
    echo "  2) Eigen domein           bv. node1.wiredhosting.nl"
    echo "  3) Geen SSL               alleen als je panel ook op http draait"
    read -rp "  Keuze [1]: " c
    case "${c:-1}" in
      2) NODE_DOMAIN_MODE="domain"
         while :; do
           ask_default NODE_FQDN "Node domein" ""
           if is_domain "$NODE_FQDN" && ! is_ip "$NODE_FQDN"; then break; fi
           warn "Dat lijkt geen geldig domein."
         done
         ;;
      3) NODE_DOMAIN_MODE="none" ;;
      *) NODE_DOMAIN_MODE="sslip" ;;
    esac
    if [ "$NODE_DOMAIN_MODE" != "none" ]; then
      ask_default ADMIN_EMAIL "E-mailadres voor Let's Encrypt (leeg = geen)" ""
    else
      warn "Zet in het panel bij deze node 'Communicate Over SSL' uit."
    fi
    ask_default TIMEZONE "Tijdzone" "$DEFAULT_TZ"
  fi

  # --------------------------------------------------------------------------
  #  Versiekeuze
  # --------------------------------------------------------------------------
  echo
  if want_panel; then
    echo -e "${BOLD}Welke Pterodactyl versie wil je installeren?${NC}"
    echo "  1) Pterodactyl 1.x     stabiel, nieuwste 1.x release (PHP ${PHP_VERSION_V1})"
    echo "  2) Pterodactyl 2.0     open beta, nieuwste 2.0 pre-release (PHP ${PHP_VERSION_V2})"
    echo "  3) Zelf een versie     bv. v1.15.1 of v2.0.0-beta.2"
    echo
    echo "  2.0 is sinds 14-10-2026 in open beta: nieuwe admin, extensies, thema's."
    echo "  Pterodactyl zelf zegt: eerst op een testpanel proberen, productie op 1.x."
    read -rp "  Keuze [1]: " c
    case "${c:-1}" in
      2) PANEL_CHANNEL="v2" ;;
      3) read -rp "  Versie tag: " PANEL_CHANNEL
         PANEL_CHANNEL="$(norm_tag "${PANEL_CHANNEL:-v1}")"
         ;;
      *) PANEL_CHANNEL="v1" ;;
    esac
    WINGS_CHANNEL="v1"
  else
    echo -e "${BOLD}Welke Wings versie wil je installeren?${NC}"
    echo "  1) Nieuwste Wings 1.x  werkt met panel 1.x en 2.0"
    echo "  2) Zelf een versie     bv. v1.13.3"
    read -rp "  Keuze [1]: " c
    PANEL_CHANNEL="v1"
    case "${c:-1}" in
      2) read -rp "  Versie tag: " WINGS_CHANNEL
         WINGS_CHANNEL="$(norm_tag "${WINGS_CHANNEL:-v1}")"
         ;;
      *) WINGS_CHANNEL="v1" ;;
    esac
  fi

  # --------------------------------------------------------------------------
  #  Database host voor klanten
  # --------------------------------------------------------------------------
  echo
  echo -e "${BOLD}Database host voor klanten${NC}"
  echo "Hiermee kunnen klanten databases aanmaken voor hun server en vanaf hun"
  echo "eigen pc verbinden (HeidiSQL, DBeaver, Navicat). MySQL gaat dan luisteren"
  echo "op 0.0.0.0."
  echo
  yesno "Database host instellen?" "j"; SETUP_DBHOST=$REPLY_BOOL

  if [ "$SETUP_DBHOST" -eq 1 ]; then
    local dbhost_def
    if want_panel; then
      case "$PANEL_DOMAIN_MODE" in
        sslip)  dbhost_def="$sslip" ;;
        domain) dbhost_def="$FQDN" ;;
        *)      dbhost_def="$pub_ip" ;;
      esac
    elif [ "${NODE_DOMAIN_MODE:-none}" = "sslip" ]; then
      dbhost_def="$sslip"
    else
      dbhost_def="${NODE_FQDN:-$pub_ip}"
    fi
    ask_valid DBHOST_NAME "Naam van de database host in het panel" "$DEFAULT_DBHOST_NAME" valid_text "Gebruik letters, cijfers, spaties en - _ . ( )"
    while :; do
      ask_default DBHOST_FQDN "Hostname of IP die klanten te zien krijgen" "$dbhost_def"
      if is_ip "$DBHOST_FQDN" || is_domain "$DBHOST_FQDN"; then break; fi
      warn "Vul een geldig domein of IP-adres in."
    done
    ask_valid DBADMIN_USER "Naam van de beheeraccount" "$DEFAULT_DBADMIN_USER" valid_dbuser "Alleen letters, cijfers en _ (max 32 tekens)."

    echo
    echo "  Vanaf welk IP mag de beheeraccount verbinden?"
    echo "    1) 127.0.0.1    alleen deze server (aanbevolen)"
    echo "    2) %            elk IP (makkelijkst, minst veilig)"
    echo "    3) zelf invullen"
    read -rp "  Keuze [1]: " c
    case "${c:-1}" in
      2) DBADMIN_HOST="%" ;;
      3) ask_valid DBADMIN_HOST "  IP of patroon" "127.0.0.1" valid_dbhostpattern "Geen geldig IP of patroon." ;;
      *) DBADMIN_HOST="127.0.0.1" ;;
    esac

    if [ "$DBADMIN_HOST" = "%" ]; then
      echo
      warn "'${DBADMIN_USER}'@'%' met GRANT OPTION is een root-achtig account dat"
      warn "vanaf het hele internet bereikbaar is. Zet er fail2ban op."
    fi
  fi

  # --------------------------------------------------------------------------
  #  Node automatisch aanmelden
  # --------------------------------------------------------------------------
  AUTO_NODE=0
  if want_node; then
    echo
    echo -e "${BOLD}Node aanmelden bij het panel${NC}"
    if want_panel; then
      echo "Het panel staat op deze machine. De installer kan de locatie en node zelf"
      echo "aanmaken, de Wings-config ophalen en Wings starten."
      yesno "Node automatisch aanmelden?" "j"; AUTO_NODE=$REPLY_BOOL
    else
      echo "Met een Application API key van je panel kan de installer de node daar"
      echo "zelf aanmaken, de config ophalen en Wings starten. Maak de key aan onder"
      echo "Admin > Application API, met Read & Write op Nodes, Locations en Allocations."
      yesno "Node automatisch aanmelden?" "j"; AUTO_NODE=$REPLY_BOOL
      if [ "$AUTO_NODE" -eq 1 ]; then
        read -rp "Panel URL (bv. https://panel.wiredhosting.nl): " PANEL_URL
        PANEL_URL="${PANEL_URL%/}"
        read -rsp "Application API key: " PANEL_API_KEY; echo
        if ! echo "$PANEL_URL" | grep -qE '^https?://' || [ -z "$PANEL_API_KEY" ]; then
          warn "Geen geldige URL of lege key. De node meld je straks handmatig aan."
          AUTO_NODE=0
        fi
      fi
    fi

    if [ "$AUTO_NODE" -eq 1 ]; then
      ask_valid NODE_NAME "Naam van de node" "$DEFAULT_NODE_NAME" valid_name "Gebruik letters, cijfers, spaties en - _ ."
      LOCATION_ID=""
      if ! want_panel; then
        while :; do
          read -rp "Bestaande locatie ID in het panel (leeg = nieuwe aanmaken): " LOCATION_ID
          [ -z "$LOCATION_ID" ] || echo "$LOCATION_ID" | grep -qE '^[0-9]+$' && break
          warn "Een locatie ID is een getal."
        done
      fi
      if [ -z "$LOCATION_ID" ]; then
        ask_valid LOCATION_SHORT "Code voor de nieuwe locatie" "$DEFAULT_LOCATION_SHORT" valid_short "Gebruik letters, cijfers en - _ . (geen spaties)."
        ask_valid LOCATION_LONG "Omschrijving van de locatie" "${COMPANY} Nederland" valid_text "Gebruik letters, cijfers, spaties en - _ . , ( )"
      fi
      while :; do
        read -rp "Poortbereik voor gameservers, bv. 25565-25600 (leeg = overslaan): " ALLOC_PORTS
        ALLOC_PORTS="$(echo "${ALLOC_PORTS:-}" | tr -d ' ')"
        [ -z "$ALLOC_PORTS" ] || valid_ports "$ALLOC_PORTS" && break
        warn "Dat is geen geldig poortbereik. Voorbeeld: 25565-25600 of 25565,25570-25580"
      done
    fi
  fi

  if [ "$OS_FAMILY" = "debian" ]; then
    yesno "Firewall (UFW) configureren?" "j"; SETUP_FW=$REPLY_BOOL
  else
    yesno "Firewall (firewalld) configureren?" "j"; SETUP_FW=$REPLY_BOOL
  fi
}

# ----------------------------------------------------------------------------
#  Config uit een bestand (webinstaller)
# ----------------------------------------------------------------------------
load_config() {
  [ -n "$CONFIG_FILE" ] && [ -f "$CONFIG_FILE" ] || fail "Config bestand niet gevonden: ${CONFIG_FILE:-leeg}"
  [ "$(stat -c '%u' "$CONFIG_FILE")" = "0" ] || fail "Config bestand moet van root zijn."
  # shellcheck disable=SC1090
  . "$CONFIG_FILE"
  PANEL_URL="${PANEL_URL:-}"; PANEL_URL="${PANEL_URL%/}"
  ALLOC_PORTS="$(echo "${ALLOC_PORTS:-}" | tr -d ' ')"
  PANEL_CHANNEL="$(norm_tag "${PANEL_CHANNEL:-v1}")"
  WINGS_CHANNEL="$(norm_tag "${WINGS_CHANNEL:-v1}")"
}

CFG_ERRORS=0
cfg_err() {
  CFG_ERRORS=$((CFG_ERRORS + 1))
  if [ "$RUN_MODE" = "check" ]; then echo "@@ERR|$1|$2"; else warn "$2"; fi
}

is_bool() { [ "${1:-}" = "0" ] || [ "${1:-}" = "1" ]; }

validate_config() {
  case "${INSTALL_MODE:-}" in
    both|panel|node|phpfix) ;;
    *) cfg_err INSTALL_MODE "Kies wat je wilt installeren."; return 0 ;;
  esac
  [ "$INSTALL_MODE" = "phpfix" ] && return 0

  if want_panel; then
    [ -f "$PANEL_DIR/.env" ] && cfg_err INSTALL_MODE "Er staat al een panel in $PANEL_DIR. Gebruik een schone server."
    case "${PANEL_DOMAIN_MODE:-}" in
      sslip|ip) ;;
      domain)
        if is_ip "${FQDN:-}" || ! is_domain "${FQDN:-}"; then
          cfg_err FQDN "Vul een geldig domein in (geen IP-adres)."
        fi
        is_bool "${USE_SSL:-}" || cfg_err USE_SSL "Kies of je SSL wilt."
        ;;
      *) cfg_err PANEL_DOMAIN_MODE "Kies een adres voor het panel." ;;
    esac
    valid_email "${ADMIN_EMAIL:-}" || cfg_err ADMIN_EMAIL "Vul een geldig e-mailadres in."
    valid_user "${ADMIN_USER:-}" || cfg_err ADMIN_USER "Gebruikersnaam: alleen kleine letters, cijfers, punt, streep en underscore."
    [ -n "${ADMIN_FIRST:-}" ] && [ "${#ADMIN_FIRST}" -le 191 ] || cfg_err ADMIN_FIRST "Vul een voornaam in."
    [ -n "${ADMIN_LAST:-}" ] && [ "${#ADMIN_LAST}" -le 191 ] || cfg_err ADMIN_LAST "Vul een achternaam in."
    if [ -n "${ADMIN_PASS:-}" ] && [ "${#ADMIN_PASS}" -lt 8 ]; then
      cfg_err ADMIN_PASS "Het wachtwoord moet minimaal 8 tekens zijn."
    fi
    if [ -z "${TIMEZONE:-}" ] || { [ -d /usr/share/zoneinfo ] && [ ! -f "/usr/share/zoneinfo/${TIMEZONE}" ]; }; then
      cfg_err TIMEZONE "Onbekende tijdzone, bv. Europe/Amsterdam."
    fi
    valid_dbname "${DB_NAME:-}" || cfg_err DB_NAME "Databasenaam: alleen letters, cijfers en _ (max 64)."
    valid_dbuser "${DB_USER:-}" || cfg_err DB_USER "Database gebruiker: alleen letters, cijfers en _ (max 32)."
    if [ -n "${DB_PASS:-}" ] && ! valid_secret "$DB_PASS"; then
      cfg_err DB_PASS "Database wachtwoord: 8-64 tekens, geen spaties, quotes, \$ of backslash."
    fi
    echo "${PANEL_CHANNEL:-}" | grep -qE '^(v1|v2|v[0-9]+\.[0-9]+\.[0-9]+[A-Za-z0-9.-]*)$' \
      || cfg_err PANEL_CHANNEL "Onbekende panel versie."
  fi

  if want_node && ! want_panel; then
    case "${NODE_DOMAIN_MODE:-}" in
      sslip|none) ;;
      domain)
        if is_ip "${NODE_FQDN:-}" || ! is_domain "${NODE_FQDN:-}"; then
          cfg_err NODE_FQDN "Vul een geldig domein in voor de node."
        fi
        ;;
      *) cfg_err NODE_DOMAIN_MODE "Kies een adres voor de node." ;;
    esac
    if [ -n "${ADMIN_EMAIL:-}" ] && ! valid_email "$ADMIN_EMAIL"; then
      cfg_err ADMIN_EMAIL "Vul een geldig e-mailadres in, of laat het leeg."
    fi
    if [ -d /usr/share/zoneinfo ] && [ ! -f "/usr/share/zoneinfo/${TIMEZONE:-x}" ]; then
      cfg_err TIMEZONE "Onbekende tijdzone, bv. Europe/Amsterdam."
    fi
  fi
  if want_node; then
    echo "${WINGS_CHANNEL:-}" | grep -qE '^(v1|v[0-9]+\.[0-9]+\.[0-9]+[A-Za-z0-9.-]*)$' \
      || cfg_err WINGS_CHANNEL "Onbekende Wings versie."
  fi

  is_bool "${SETUP_DBHOST:-}" || cfg_err SETUP_DBHOST "Kies of je een database host wilt."
  if [ "${SETUP_DBHOST:-0}" = "1" ]; then
    valid_text "${DBHOST_NAME:-}" || cfg_err DBHOST_NAME "Naam van de database host: letters, cijfers, spaties en - _ . ( )"
    if [ -n "${DBHOST_FQDN:-}" ] && ! is_ip "$DBHOST_FQDN" && ! is_domain "$DBHOST_FQDN"; then
      cfg_err DBHOST_FQDN "Vul een geldig domein of IP-adres in."
    fi
    valid_dbuser "${DBADMIN_USER:-}" || cfg_err DBADMIN_USER "Beheeraccount: alleen letters, cijfers en _ (max 32)."
    valid_dbhostpattern "${DBADMIN_HOST:-}" || cfg_err DBADMIN_HOST "Geen geldig IP of patroon."
  fi

  is_bool "${AUTO_NODE:-0}" || cfg_err AUTO_NODE "Kies of de node automatisch aangemeld moet worden."
  if want_node && [ "${AUTO_NODE:-0}" = "1" ]; then
    valid_name "${NODE_NAME:-}" || cfg_err NODE_NAME "Node naam: letters, cijfers, spaties en - _ ."
    if [ -n "${LOCATION_ID:-}" ]; then
      echo "$LOCATION_ID" | grep -qE '^[0-9]+$' || cfg_err LOCATION_ID "Een locatie ID is een getal."
    else
      valid_short "${LOCATION_SHORT:-}" || cfg_err LOCATION_SHORT "Locatiecode: letters, cijfers en - _ . (geen spaties)."
      valid_text "${LOCATION_LONG:-}" || cfg_err LOCATION_LONG "Omschrijving: letters, cijfers, spaties en - _ . , ( )"
    fi
    if [ -n "${ALLOC_PORTS:-}" ] && ! valid_ports "$ALLOC_PORTS"; then
      cfg_err ALLOC_PORTS "Geen geldig poortbereik, bv. 25565-25600."
    fi
    if ! want_panel; then
      echo "${PANEL_URL:-}" | grep -qE '^https?://[A-Za-z0-9.-]+(:[0-9]+)?(/.*)?$' \
        || cfg_err PANEL_URL "Vul de URL van je panel in, bv. https://panel.wiredhosting.nl"
      echo "${PANEL_API_KEY:-}" | grep -qE '^[A-Za-z0-9_.-]{20,}$' \
        || cfg_err PANEL_API_KEY "Vul een geldige Application API key in (begint meestal met ptla_)."
    fi
  fi
  if want_node; then
    local p
    for p in NODE_MEM_MB NODE_DISK_MB; do
      if [ -n "${!p:-}" ] && ! echo "${!p}" | grep -qE '^[0-9]{3,9}$'; then
        cfg_err "$p" "Vul een getal in megabytes in, of laat het leeg voor automatisch."
      fi
    done
    valid_port "${NODE_DAEMON_PORT:-}" || cfg_err NODE_DAEMON_PORT "Geen geldige poort."
    valid_port "${NODE_SFTP_PORT:-}" || cfg_err NODE_SFTP_PORT "Geen geldige poort."
    for p in NODE_DAEMON_PORT NODE_SFTP_PORT; do
      case "${!p:-}" in
        22|80|443|3306|"${WEBINSTALLER_PORT:-x}")
          cfg_err "$p" "Poort ${!p} is al in gebruik door iets anders." ;;
      esac
    done
    if [ -n "${NODE_DAEMON_PORT:-}" ] && [ "${NODE_DAEMON_PORT:-}" = "${NODE_SFTP_PORT:-}" ]; then
      cfg_err NODE_SFTP_PORT "De SFTP poort moet anders zijn dan de daemon poort."
    fi
  fi

  is_bool "${SETUP_FW:-}" || cfg_err SETUP_FW "Kies of de firewall ingesteld moet worden."
  return 0
}

# ----------------------------------------------------------------------------
#  Afgeleide instellingen (terminal en webinstaller)
# ----------------------------------------------------------------------------
finalize_config() {
  PUBLIC_IP="${PUBLIC_IP:-$(detect_ip)}"
  USE_SSL="${USE_SSL:-0}"
  PANEL_IS_IP=0

  DB_NAME="${DB_NAME:-$DEFAULT_DB_NAME}"
  DB_USER="${DB_USER:-$DEFAULT_DB_USER}"
  DBHOST_NAME="${DBHOST_NAME:-$DEFAULT_DBHOST_NAME}"
  DBADMIN_USER="${DBADMIN_USER:-$DEFAULT_DBADMIN_USER}"
  DBADMIN_HOST="${DBADMIN_HOST:-127.0.0.1}"
  NODE_NAME="${NODE_NAME:-$DEFAULT_NODE_NAME}"
  LOCATION_ID="${LOCATION_ID:-}"
  LOCATION_SHORT="${LOCATION_SHORT:-$DEFAULT_LOCATION_SHORT}"
  LOCATION_LONG="${LOCATION_LONG:-${COMPANY} Nederland}"
  ALLOC_PORTS="${ALLOC_PORTS:-}"
  NODE_DAEMON_PORT="${NODE_DAEMON_PORT:-$DEFAULT_DAEMON_PORT}"
  NODE_SFTP_PORT="${NODE_SFTP_PORT:-$DEFAULT_SFTP_PORT}"
  NODE_FQDN="${NODE_FQDN:-}"
  TIMEZONE="${TIMEZONE:-$DEFAULT_TZ}"
  ADMIN_EMAIL="${ADMIN_EMAIL:-}"
  SETUP_DBHOST="${SETUP_DBHOST:-0}"
  AUTO_NODE="${AUTO_NODE:-0}"
  SETUP_FW="${SETUP_FW:-0}"

  if want_panel; then
    case "${PANEL_DOMAIN_MODE:-domain}" in
      sslip)
        [ -n "$PUBLIC_IP" ] || fail "Kan het publieke IP van deze server niet bepalen, sslip.io werkt dan niet."
        FQDN="$(sslip_host "$PUBLIC_IP")"; USE_SSL=1 ;;
      ip)
        FQDN="$PUBLIC_IP"; USE_SSL=0; PANEL_IS_IP=1 ;;
      *)
        if is_ip "$FQDN"; then USE_SSL=0; PANEL_IS_IP=1; fi ;;
    esac
  elif want_node; then
    case "${NODE_DOMAIN_MODE:-none}" in
      sslip)
        [ -n "$PUBLIC_IP" ] || fail "Kan het publieke IP van deze server niet bepalen, sslip.io werkt dan niet."
        NODE_FQDN="$(sslip_host "$PUBLIC_IP")"; USE_SSL=1 ;;
      domain)
        USE_SSL=1 ;;
      *)
        NODE_FQDN=""; USE_SSL=0 ;;
    esac
  fi

  if want_panel; then
    if [ -z "${ADMIN_PASS:-}" ]; then
      ADMIN_PASS="$(rand_pass)"
      GENERATED_PASS=1
    fi
    [ -n "${DB_PASS:-}" ] || DB_PASS="$(rand_pass)"
  fi

  if [ "$SETUP_DBHOST" -eq 1 ]; then
    [ -n "${DBHOST_FQDN:-}" ] || DBHOST_FQDN="${FQDN:-${NODE_FQDN:-$PUBLIC_IP}}"
    DBADMIN_PASS="$(rand_pass)"
  fi

  want_node && INSTALL_WINGS=1 || INSTALL_WINGS=0

  case "$INSTALL_MODE" in
    both)  MODE_LABEL="panel + node" ;;
    panel) MODE_LABEL="alleen panel" ;;
    node)  MODE_LABEL="alleen node (Wings)" ;;
  esac
}

# Vraag in de terminal, in de webinstaller is dat al bevestigd
confirm_or_fail() {
  if [ "$RUN_MODE" = "interactive" ]; then
    yesno "$1" "$2"
    [ "$REPLY_BOOL" -eq 1 ] || fail "$3"
  elif [ "$2" = "n" ]; then
    fail "$3"
  fi
}

resolve_versions() {
  info "Versie opzoeken, moment"
  if want_panel; then
    case "$PANEL_CHANNEL" in
      v2) PANEL_VERSION="$(resolve_version panel "$PANEL_CHANNEL" "$FALLBACK_PANEL_V2_VERSION")" ;;
      *)  PANEL_VERSION="$(resolve_version panel "$PANEL_CHANNEL" "$FALLBACK_PANEL_V1_VERSION")" ;;
    esac
    PANEL_MAJOR="$(echo "$PANEL_VERSION" | grep -oE '[0-9]+' | head -n1)"
    # Wings heeft geen 2.0: Wings 1.13.x werkt met zowel panel 1.x als 2.0
    WINGS_CHANNEL="v1"
  else
    PANEL_VERSION=""
    PANEL_MAJOR="1"
  fi
  WINGS_VERSION="$(resolve_version wings "${WINGS_CHANNEL:-v1}" "$FALLBACK_WINGS_VERSION")"

  case "${PANEL_MAJOR:-1}" in
    1)
      PHP_VERSION="$PHP_VERSION_V1"
      DOCS_URL="$DOCS_URL_V1"
      ;;
    2)
      PHP_VERSION="$PHP_VERSION_V2"
      DOCS_URL="$DOCS_URL_V2"
      echo
      warn "Panel $PANEL_VERSION is een 2.0 release. 2.0 is open beta en nog niet"
      warn "bedoeld voor productie. Extensies, thema's en de upgrade vanaf 1.x zijn"
      warn "nog in ontwikkeling. Docs: $DOCS_URL_V2"
      if [ "$OS_FAMILY" = "rhel" ]; then
        warn "2.0 is officieel alleen getest op Ubuntu en Debian, niet op $NAME."
      elif [ "$OS_ID" = "debian" ] && [ "$OS_VERSION_ID" = "11" ]; then
        warn "Debian 11 wordt door 2.0 niet ondersteund (wel door 1.x)."
      fi
      confirm_or_fail "  Doorgaan met $PANEL_VERSION?" "j" "Geannuleerd. Kies de stabiele 1.x."
      ;;
    *)
      echo
      warn "Panel $PANEL_VERSION is een ${PANEL_MAJOR}.x release en dat kent dit script niet."
      warn "De installatiestappen van 1.x/2.0 gaan hier waarschijnlijk niet op werken."
      confirm_or_fail "  Toch proberen met $PANEL_VERSION?" "n" "Geannuleerd. Kies de stabiele 1.x."
      PHP_VERSION="$PHP_VERSION_V2"
      DOCS_URL="$DOCS_URL_V2"
      ;;
  esac
  set_php_paths

  if want_panel; then
    ok "Panel $PANEL_VERSION / Wings $WINGS_VERSION / PHP $PHP_VERSION"
  else
    ok "Wings $WINGS_VERSION"
  fi
}

ssl_label() {
  if [ "$USE_SSL" -eq 1 ]; then
    if [ "${PANEL_DOMAIN_MODE:-}" = "sslip" ] || [ "${NODE_DOMAIN_MODE:-}" = "sslip" ]; then
      echo "ja, gratis via sslip.io + Let's Encrypt"
    else
      echo "ja, Let's Encrypt"
    fi
  elif [ "${PANEL_IS_IP:-0}" -eq 1 ]; then
    echo "nee (IP-adres)"
  else
    echo "nee"
  fi
}

show_summary() {
  echo
  echo "-----------------------------------------------"
  echo -e "  Installeert   : ${BOLD}$MODE_LABEL${NC}"
  echo -e "  OS            : $PRETTY_NAME"
  if want_panel; then
    echo -e "  Panel adres   : ${BOLD}$([ "$USE_SSL" -eq 1 ] && echo https || echo http)://$FQDN${NC}"
    echo -e "  Admin         : $ADMIN_USER <$ADMIN_EMAIL>"
    echo -e "  Panel versie  : ${BOLD}$PANEL_VERSION${NC}"
    echo -e "  PHP           : $PHP_VERSION"
    echo -e "  Database      : $DB_NAME  (gebruiker $DB_USER)"
  elif [ -n "${NODE_FQDN:-}" ]; then
    echo -e "  Node adres    : ${BOLD}$NODE_FQDN${NC}"
  fi
  echo -e "  Tijdzone      : $TIMEZONE"
  echo -e "  SSL           : $(ssl_label)"
  if want_node; then
    echo -e "  Wings versie  : ${BOLD}$WINGS_VERSION${NC}"
  fi
  if [ "$SETUP_DBHOST" -eq 1 ]; then
    echo -e "  Database host : ja  ($DBHOST_NAME, $DBHOST_FQDN, ${DBADMIN_USER}@${DBADMIN_HOST})"
  else
    echo -e "  Database host : nee"
  fi
  if want_node; then
    if [ "$AUTO_NODE" -eq 1 ]; then
      echo -e "  Node aanmelden: automatisch  (${NODE_NAME}, locatie ${LOCATION_ID:-$LOCATION_SHORT}${ALLOC_PORTS:+, poorten $ALLOC_PORTS})"
    else
      echo -e "  Node aanmelden: handmatig"
    fi
    echo -e "  Wings poorten : daemon ${NODE_DAEMON_PORT}, SFTP ${NODE_SFTP_PORT}"
  fi
  echo -e "  Firewall      : $([ "$SETUP_FW" -eq 1 ] && echo 'ja' || echo 'nee')"
  echo "-----------------------------------------------"
  echo

  if [ "$RUN_MODE" = "interactive" ]; then
    local confirm
    read -rp "Klopt dit? Doorgaan met installeren? (j/n): " confirm
    confirm="$(echo "$confirm" | tr '[:upper:]' '[:lower:]')"
    [[ "$confirm" == "j" || "$confirm" == "y" ]] || fail "Geannuleerd."
  fi

  if [ "$USE_SSL" -eq 1 ]; then
    if [ "${PANEL_DOMAIN_MODE:-}" = "sslip" ] || [ "${NODE_DOMAIN_MODE:-}" = "sslip" ]; then
      info "sslip.io wijst ${FQDN:-$NODE_FQDN} automatisch naar ${PUBLIC_IP}, geen DNS nodig."
      info "Poort 80 moet wel van buitenaf bereikbaar zijn voor Let's Encrypt."
    else
      warn "Zorg dat de A/AAAA record van ${FQDN:-$NODE_FQDN} naar deze server wijst,"
      warn "anders faalt Let's Encrypt."
      [ "$RUN_MODE" = "interactive" ] && sleep 3
    fi
  fi
}

# ----------------------------------------------------------------------------
#  Servergegevens voor de webinstaller (--info)
# ----------------------------------------------------------------------------
print_info() {
  local ip supported=0 mem disk
  if ( preflight ) >/dev/null 2>&1; then supported=1; fi
  # shellcheck disable=SC1091
  . /etc/os-release 2>/dev/null || true
  ip="$(detect_ip)"
  mem="$(free -m 2>/dev/null | awk '/^Mem:/{print $2}' || true)"
  disk="$(df -m /var/lib 2>/dev/null | awk 'NR==2{print $4}' || true)"
  echo "@@INFO|os|${PRETTY_NAME:-onbekend}"
  echo "@@INFO|os_supported|${supported}"
  echo "@@INFO|arch|$(uname -m)"
  echo "@@INFO|hostname|$(hostname -f 2>/dev/null || hostname)"
  echo "@@INFO|public_ip|${ip}"
  [ -n "$ip" ] && echo "@@INFO|sslip_host|$(sslip_host "$ip")"
  echo "@@INFO|mem_mb|${mem}"
  echo "@@INFO|disk_mb|${disk}"
  echo "@@INFO|panel_exists|$([ -f "$PANEL_DIR/.env" ] && echo 1 || echo 0)"
  echo "@@INFO|wings_exists|$([ -f /usr/local/bin/wings ] && echo 1 || echo 0)"
  echo "@@INFO|default_tz|${DEFAULT_TZ}"
  echo "@@INFO|php_v1|${PHP_VERSION_V1}"
  echo "@@INFO|php_v2|${PHP_VERSION_V2}"
}

# ----------------------------------------------------------------------------
#  Repositories en pakketten
# ----------------------------------------------------------------------------
install_base() {
  info "Basispakketten installeren"
  pkg_update
  if [ "$OS_FAMILY" = "debian" ]; then
    pkg_install ca-certificates curl gnupg lsb-release tar unzip git openssl "$CRON_PKG"
    # add-apt-repository zit in software-properties-common. Alleen nodig op
    # Ubuntu (voor de PPA); Debian 13 heeft dat pakket niet meer, en
    # apt-transport-https is daar ook verdwenen (zit in apt zelf).
    if [ "$OS_ID" = "ubuntu" ]; then
      pkg_install software-properties-common
    fi
  else
    pkg_install ca-certificates curl tar unzip git openssl "$CRON_PKG" dnf-utils
    systemctl enable --now crond >/dev/null 2>&1 || true
    if selinux_active; then
      pkg_install policycoreutils policycoreutils-python-utils selinux-policy selinux-policy-targeted
    fi
  fi
  ok "Basispakketten klaar"
}

install_mariadb() {
  if command -v mysqld >/dev/null 2>&1 || command -v mariadbd >/dev/null 2>&1 \
     || rpm -q mariadb-server >/dev/null 2>&1 \
     || dpkg -l 2>/dev/null | grep -q '^ii.*mariadb-server'; then
    return 0
  fi
  info "MariaDB installeren"
  pkg_install mariadb-server
  systemctl enable --now mariadb >/dev/null 2>&1 || true
  ok "MariaDB klaar"
}

# PHP repo: Sury/Ondrej op Debian/Ubuntu, Remi op Enterprise Linux.
# Beide hebben de nieuwste builds (en dus de PHP2Shell fix) eerder dan de
# standaard distro repo.
setup_php_repo() {
  info "PHP repository voorbereiden"
  case "$OS_ID" in
    ubuntu)
      if ! grep -rq "ondrej/php" /etc/apt/sources.list.d/ 2>/dev/null; then
        LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php >/dev/null
      fi
      ;;
    debian)
      curl -fsSLo /usr/share/keyrings/deb.sury.org-php.gpg https://packages.sury.org/php/apt.gpg
      echo "deb [signed-by=/usr/share/keyrings/deb.sury.org-php.gpg] https://packages.sury.org/php/ ${OS_CODENAME} main" \
        > /etc/apt/sources.list.d/php.list
      ;;
    *)
      pkg_install epel-release 2>/dev/null \
        || dnf install -y -q "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${OS_MAJOR}.noarch.rpm" >/dev/null
      rpm -q remi-release >/dev/null 2>&1 \
        || dnf install -y -q "https://rpms.remirepo.net/enterprise/remi-release-${OS_MAJOR}.rpm" >/dev/null
      dnf module reset -y -q php >/dev/null 2>&1 || true
      dnf module enable -y -q "php:remi-${PHP_VERSION}" >/dev/null
      ;;
  esac
  pkg_update
}

install_deps() {
  setup_php_repo

  info "PHP ${PHP_VERSION}, MariaDB, nginx en Redis installeren"
  if [ "$OS_FAMILY" = "debian" ]; then
    pkg_install \
      "php${PHP_VERSION}" php${PHP_VERSION}-{cli,common,gd,mysql,mbstring,bcmath,xml,fpm,curl,zip,intl} \
      mariadb-server nginx "$REDIS_PKG"
  else
    pkg_install php php-{cli,common,gd,mysqlnd,mbstring,bcmath,xml,fpm,curl,zip,intl} \
      mariadb mariadb-server nginx "$REDIS_PKG"
    setup_php_fpm_pool_rhel
  fi

  info "Composer installeren"
  curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer >/dev/null

  systemctl enable --now mariadb "$REDIS_SVC" "$PHP_FPM_SVC" nginx >/dev/null 2>&1 || true
  ok "Afhankelijkheden geinstalleerd"

  check_php_patched "$PHP_BIN"
}

# Op Enterprise Linux draait PHP-FPM standaard als 'apache'. Pterodactyl wil
# een eigen pool onder de nginx user, met een eigen socket.
setup_php_fpm_pool_rhel() {
  info "PHP-FPM pool voor Pterodactyl aanmaken"
  cat > /etc/php-fpm.d/www-pterodactyl.conf <<EOF
[pterodactyl]

user = ${WEB_USER}
group = ${WEB_USER}

listen = ${PHP_FPM_SOCK}
listen.owner = ${WEB_USER}
listen.group = ${WEB_USER}
listen.mode = 0750

pm = ondemand
pm.max_children = 9
pm.process_idle_timeout = 10s
pm.max_requests = 200
EOF
  mkdir -p /var/run/php-fpm
  systemctl restart "$PHP_FPM_SVC" >/dev/null 2>&1 || true
}

# SELinux: nginx mag naar Redis/MariaDB verbinden en in storage schrijven
setup_selinux() {
  selinux_active || return 0
  info "SELinux booleans en file contexts zetten"
  setsebool -P httpd_can_network_connect 1 2>/dev/null || true
  setsebool -P httpd_execmem 1 2>/dev/null || true
  setsebool -P httpd_unified 1 2>/dev/null || true
  if command -v semanage >/dev/null 2>&1; then
    # eerst de algemene regel, daarna de specifiekere schrijfbare mappen
    semanage fcontext -a -t httpd_sys_content_t "${PANEL_DIR}(/.*)?" 2>/dev/null || true
    semanage fcontext -a -t httpd_sys_rw_content_t "${PANEL_DIR}/storage(/.*)?" 2>/dev/null || true
    semanage fcontext -a -t httpd_sys_rw_content_t "${PANEL_DIR}/bootstrap/cache(/.*)?" 2>/dev/null || true
  fi
  restorecon -R "$PANEL_DIR" 2>/dev/null || true
  ok "SELinux ingesteld"
}

# ----------------------------------------------------------------------------
#  Database voor het panel zelf
# ----------------------------------------------------------------------------
setup_db() {
  info "Database '${DB_NAME}' aanmaken"
  dbcli -u root <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';
ALTER USER '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'127.0.0.1' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL
  ok "Database '${DB_NAME}' klaar (gebruiker ${DB_USER})"
}

# ----------------------------------------------------------------------------
#  Database host voor klanten
# ----------------------------------------------------------------------------
setup_dbhost() {
  info "MySQL openzetten voor klantdatabases"

  # bind-address op 0.0.0.0 zetten in het juiste config bestand
  local cfg=""
  for f in /etc/mysql/mariadb.conf.d/50-server.cnf \
           /etc/mysql/mysql.conf.d/mysqld.cnf \
           /etc/mysql/my.cnf \
           /etc/my.cnf.d/mariadb-server.cnf \
           /etc/my.cnf.d/server.cnf; do
    [ -f "$f" ] && grep -q "bind-address" "$f" && { cfg="$f"; break; }
  done

  if [ -n "$cfg" ]; then
    cp "$cfg" "${cfg}.wiredhosting.bak"
    sed -i 's/^[[:space:]]*#\?[[:space:]]*bind-address.*/bind-address = 0.0.0.0/' "$cfg"
    ok "bind-address = 0.0.0.0 in $cfg"
  else
    mkdir -p "$MYSQL_CONF_DIR"
    printf '[mysqld]\nbind-address = 0.0.0.0\n' > "${MYSQL_CONF_DIR}/99-wiredhosting.cnf"
    ok "bind-address = 0.0.0.0 in ${MYSQL_CONF_DIR}/99-wiredhosting.cnf"
  fi

  systemctl restart mariadb
  sleep 2

  # Bij 'alleen deze server' verbindt het panel straks naar ${DBHOST_FQDN}, en
  # dan komt de verbinding binnen vanaf het eigen IP van de server, niet vanaf
  # 127.0.0.1. Daarom het account ook aanmaken voor de lokale en publieke IP's.
  local hosts="$DBADMIN_HOST" h
  if [ "$DBADMIN_HOST" = "127.0.0.1" ]; then
    hosts="127.0.0.1 localhost $(hostname -I 2>/dev/null || true) $(detect_ip)"
  fi
  DBADMIN_HOSTS="$(echo "$hosts" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ')"

  info "Beheeraccount '${DBADMIN_USER}' aanmaken voor: ${DBADMIN_HOSTS}"
  for h in $DBADMIN_HOSTS; do
    dbcli -u root <<SQL
CREATE USER IF NOT EXISTS '${DBADMIN_USER}'@'${h}' IDENTIFIED BY '${DBADMIN_PASS}';
ALTER USER '${DBADMIN_USER}'@'${h}' IDENTIFIED BY '${DBADMIN_PASS}';
GRANT ALL PRIVILEGES ON *.* TO '${DBADMIN_USER}'@'${h}' WITH GRANT OPTION;
SQL
  done
  dbcli -u root -e "FLUSH PRIVILEGES;"

  if ss -tlnp 2>/dev/null | grep -q ':3306'; then
    ok "MySQL luistert op poort 3306"
  else
    warn "MySQL lijkt niet op 3306 te luisteren, check 'systemctl status mariadb'."
  fi

  DBHOST_NOTE=1
}

# ----------------------------------------------------------------------------
#  Panel (1.x en 2.0, zelfde stappen op een schone server)
# ----------------------------------------------------------------------------
install_panel() {
  local url="https://github.com/pterodactyl/panel/releases/download/${PANEL_VERSION}/panel.tar.gz"

  info "Panel ${PANEL_VERSION} downloaden"
  url_exists "$url" || fail "Kan $url niet vinden. Bestaat de versie ${PANEL_VERSION}, en heeft die release een panel.tar.gz?"

  mkdir -p "$PANEL_DIR"
  cd "$PANEL_DIR"
  curl -fSLo panel.tar.gz "$url"
  tar -xzf panel.tar.gz
  rm -f panel.tar.gz
  chmod -R 755 storage/* bootstrap/cache/

  cp .env.example .env

  info "Dependencies installeren via Composer (dit duurt even)"
  COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader --no-interaction --quiet

  php artisan key:generate --force --no-interaction

  info "Panel configureren"
  # Bij http (IP-adres of SSL uitgezet) moet de URL ook op http staan, anders
  # zet het panel SESSION_SECURE_COOKIE aan en kun je niet inloggen.
  local panel_scheme="https"
  [ $USE_SSL -eq 1 ] || panel_scheme="http"
  php artisan p:environment:setup \
    --author="$ADMIN_EMAIL" \
    --url="${panel_scheme}://${FQDN}" \
    --timezone="$TIMEZONE" \
    --cache=redis \
    --session=redis \
    --queue=redis \
    --redis-host=127.0.0.1 \
    --redis-pass= \
    --redis-port=6379 \
    --settings-ui=true \
    --no-interaction

  php artisan p:environment:database \
    --host=127.0.0.1 \
    --port=3306 \
    --database="$DB_NAME" \
    --username="$DB_USER" \
    --password="$DB_PASS" \
    --no-interaction

  info "Database migreren en seeden"
  php artisan migrate --seed --force --no-interaction

  info "Admin account aanmaken"
  php artisan p:user:make \
    --email="$ADMIN_EMAIL" \
    --username="$ADMIN_USER" \
    --name-first="$ADMIN_FIRST" \
    --name-last="$ADMIN_LAST" \
    --password="$ADMIN_PASS" \
    --admin=1 \
    --no-interaction

  chown -R "${WEB_USER}:${WEB_USER}" "$PANEL_DIR"
  [ "$OS_FAMILY" = "rhel" ] && setup_selinux
  ok "Panel $PANEL_VERSION geinstalleerd"
}

setup_cron_queue() {
  info "Cronjob en queue worker instellen"

  # crontab -l geeft exit 1 als er nog geen crontab is, en grep -v geeft exit 1
  # bij lege invoer. Zonder || true sneuvelt dit onder set -e en pipefail.
  {
    crontab -l 2>/dev/null | grep -v "$PANEL_DIR/artisan schedule:run" || true
    echo "* * * * * php ${PANEL_DIR}/artisan schedule:run >> /dev/null 2>&1"
  } | crontab -

  cat > /etc/systemd/system/pteroq.service <<EOF
[Unit]
Description=Pterodactyl Queue Worker (WiredHosting)
After=${REDIS_SVC}.service

[Service]
User=${WEB_USER}
Group=${WEB_USER}
Restart=always
ExecStart=/usr/bin/php ${PANEL_DIR}/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now pteroq.service >/dev/null
  ok "Queue worker draait"
}

# ----------------------------------------------------------------------------
#  Nginx
# ----------------------------------------------------------------------------
nginx_enable_site() {
  if [ "$OS_FAMILY" = "debian" ]; then
    ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/pterodactyl.conf
  fi
}

setup_nginx() {
  info "Nginx configureren"
  nginx_listen_ssl
  rm -f /etc/nginx/sites-enabled/default

  # 2.0 zet thema's en extensies in public/assets. Dat block serveert die
  # bestanden als statische files, nooit via PHP, en weigert verborgen files.
  ASSETS_BLOCK=""
  if [ "${PANEL_MAJOR:-1}" != "1" ]; then
    ASSETS_BLOCK='
    location ^~ /assets/ {
        location ~ /\. { deny all; }
        try_files $uri =404;
    }
'
  fi

  if [ $USE_SSL -eq 1 ]; then
    cat > "$NGINX_CONF" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${FQDN};
    root ${PANEL_DIR}/public;
    index index.php;
    location / { try_files \$uri \$uri/ /index.php?\$query_string; }
}
EOF
    nginx_enable_site
    nginx -t >/dev/null && systemctl reload nginx

    if have_cert "$FQDN"; then
      # bv. al aangevraagd door de webinstaller voor hetzelfde sslip.io adres
      ok "Certificaat voor $FQDN staat er al, dat wordt gebruikt"
    else
      info "Let's Encrypt certificaat aanvragen voor $FQDN"
      pkg_install certbot python3-certbot-nginx
      if certbot certonly --nginx -d "$FQDN" --non-interactive --agree-tos $(certbot_email_args) >/dev/null 2>&1; then
        ok "Certificaat uitgegeven"
      else
        warn "Let's Encrypt is mislukt. Panel wordt zonder SSL opgezet, je kunt later 'certbot --nginx -d $FQDN' draaien."
        warn "Controleer of poort 80 van buitenaf bereikbaar is (ook in de firewall van je provider)."
        USE_SSL=0
      fi
    fi
  fi

  if [ $USE_SSL -eq 1 ]; then
    note_cert_in_use "$FQDN"
    cat > "$NGINX_CONF" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${FQDN};
    return 301 https://\$server_name\$request_uri;
}

server {
$(printf '%b' "$NGINX_LISTEN")
    server_name ${FQDN};

    root ${PANEL_DIR}/public;
    index index.php;

    access_log /var/log/nginx/pterodactyl.app-access.log;
    error_log  /var/log/nginx/pterodactyl.app-error.log error;

    client_max_body_size 100m;
    client_body_timeout 120s;
    sendfile off;

    ssl_certificate     /etc/letsencrypt/live/${FQDN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${FQDN}/privkey.pem;
    ssl_session_cache shared:SSL:10m;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;

    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection "1; mode=block";
    add_header X-Frame-Options DENY;
    add_header X-Robots-Tag none;
    add_header Referrer-Policy same-origin;
    add_header Strict-Transport-Security "max-age=15768000; preload" always;
    add_header Content-Security-Policy "frame-ancestors 'self'";
    add_header X-Powered-By "${COMPANY}";

    location / { try_files \$uri \$uri/ /index.php?\$query_string; }
${ASSETS_BLOCK}
    location ~ \.php\$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        fastcgi_pass unix:${PHP_FPM_SOCK};
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param PHP_VALUE "upload_max_filesize = 100M \n post_max_size=100M";
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param HTTP_PROXY "";
        fastcgi_intercept_errors off;
        fastcgi_buffers 16 16k;
        fastcgi_buffer_size 32k;
        fastcgi_connect_timeout 300;
        fastcgi_send_timeout 300;
        fastcgi_read_timeout 300;
        include /etc/nginx/fastcgi_params;
    }

    location ~ /\.ht { deny all; }
}
EOF
  else
    cat > "$NGINX_CONF" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${FQDN};

    root ${PANEL_DIR}/public;
    index index.php;

    access_log /var/log/nginx/pterodactyl.app-access.log;
    error_log  /var/log/nginx/pterodactyl.app-error.log error;

    client_max_body_size 100m;
    client_body_timeout 120s;
    sendfile off;

    add_header X-Content-Type-Options nosniff;
    add_header X-Frame-Options DENY;
    add_header X-Robots-Tag none;
    add_header Referrer-Policy same-origin;
    add_header X-Powered-By "${COMPANY}";

    location / { try_files \$uri \$uri/ /index.php?\$query_string; }
${ASSETS_BLOCK}
    location ~ \.php\$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        fastcgi_pass unix:${PHP_FPM_SOCK};
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param PHP_VALUE "upload_max_filesize = 100M \n post_max_size=100M";
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param HTTP_PROXY "";
        fastcgi_intercept_errors off;
        fastcgi_buffers 16 16k;
        fastcgi_buffer_size 32k;
        include /etc/nginx/fastcgi_params;
    }

    location ~ /\.ht { deny all; }
}
EOF
    sed -i "s|^APP_URL=.*|APP_URL=http://${FQDN}|" "${PANEL_DIR}/.env"
    # zonder https mag de sessiecookie niet 'secure' zijn, anders kun je niet inloggen
    if grep -q '^SESSION_SECURE_COOKIE=' "${PANEL_DIR}/.env"; then
      sed -i "s|^SESSION_SECURE_COOKIE=.*|SESSION_SECURE_COOKIE=false|" "${PANEL_DIR}/.env"
    fi
    (cd "$PANEL_DIR" && php artisan config:clear --no-interaction >/dev/null 2>&1 || true)
  fi

  nginx_enable_site
  nginx -t >/dev/null || fail "Nginx config is ongeldig."
  systemctl restart nginx
  ok "Nginx draait"
}

# ----------------------------------------------------------------------------
#  SSL voor een losse node (geen nginx op deze machine)
# ----------------------------------------------------------------------------
setup_node_ssl() {
  if have_cert "$NODE_FQDN"; then
    ok "Certificaat voor $NODE_FQDN staat er al, dat wordt gebruikt"
    note_cert_in_use "$NODE_FQDN"
    return 0
  fi
  info "Certificaat aanvragen voor $NODE_FQDN"
  [ "$OS_FAMILY" = "rhel" ] && { pkg_install epel-release 2>/dev/null || true; pkg_update; }
  pkg_install certbot
  # shellcheck disable=SC2046
  if certbot certonly --standalone -d "$NODE_FQDN" \
       --non-interactive --agree-tos $(certbot_email_args) >/dev/null 2>&1; then
    ok "Certificaat staat in /etc/letsencrypt/live/${NODE_FQDN}/"
    note_cert_in_use "$NODE_FQDN"
  else
    warn "Let's Encrypt is mislukt. Draai later: certbot certonly --standalone -d $NODE_FQDN"
    warn "Poort 80 moet daarvoor vrij en bereikbaar zijn."
    USE_SSL=0
  fi
}

# ----------------------------------------------------------------------------
#  Wings (optioneel, 1.x; werkt met panel 1.x en 2.0)
# ----------------------------------------------------------------------------
install_docker() {
  info "Docker installeren"
  if command -v docker >/dev/null 2>&1; then
    ok "Docker staat er al"
  elif [ "$OS_FAMILY" = "debian" ]; then
    curl -fsSL https://get.docker.com | sh >/dev/null
  else
    pkg_install dnf-utils device-mapper-persistent-data lvm2
    dnf config-manager --add-repo=https://download.docker.com/linux/centos/docker-ce.repo >/dev/null
    pkg_install docker-ce docker-ce-cli containerd.io
  fi
  systemctl enable --now docker >/dev/null
}

enable_swap_accounting() {
  [ -f /etc/default/grub ] || return 0
  grep -q "swapaccount=1" /etc/default/grub && return 0
  sed -i 's|^GRUB_CMDLINE_LINUX_DEFAULT="|GRUB_CMDLINE_LINUX_DEFAULT="swapaccount=1 |' /etc/default/grub
  if [ "$OS_FAMILY" = "debian" ]; then
    update-grub >/dev/null 2>&1 || true
  else
    grubby --update-kernel=ALL --args="swapaccount=1" >/dev/null 2>&1 || true
  fi
  NEEDS_REBOOT=1
}

install_wings() {
  install_docker
  enable_swap_accounting

  local wurl="https://github.com/pterodactyl/wings/releases/download/${WINGS_VERSION}/wings_linux_${WINGS_ARCH}"

  info "Wings ${WINGS_VERSION} installeren"
  url_exists "$wurl" || fail "Kan $wurl niet vinden. Klopt de versie ${WINGS_VERSION} voor architectuur ${WINGS_ARCH}?"

  mkdir -p /etc/pterodactyl /var/lib/pterodactyl /var/log/pterodactyl
  curl -fSLo /usr/local/bin/wings "$wurl"
  chmod u+x /usr/local/bin/wings

  cat > /etc/systemd/system/wings.service <<'EOF'
[Unit]
Description=Pterodactyl Wings Daemon (WiredHosting)
After=docker.service
Requires=docker.service
PartOf=docker.service

[Service]
User=root
WorkingDirectory=/etc/pterodactyl
LimitNOFILE=4096
PIDFile=/var/run/wings/daemon.pid
ExecStart=/usr/local/bin/wings
Restart=on-failure
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable wings >/dev/null
  ok "Wings $WINGS_VERSION geinstalleerd (nog niet gestart, config ontbreekt)"
  WINGS_NOTE=1
}

# ----------------------------------------------------------------------------
#  Automatisch registreren in het panel
# ----------------------------------------------------------------------------
panel_artisan() { (cd "$PANEL_DIR" && php artisan "$@"); }

# PHP-snippet draaien binnen het panel via tinker (zit in beide versies).
# Het snippet gaat via een tijdelijk bestand met 0600, zodat wachtwoorden niet
# in de proceslijst terechtkomen.
panel_php() {
  local tmp="/root/.wh-panel-$$.php" out rc=0
  printf '<?php\n%s\n' "$1" > "$tmp"
  chmod 600 "$tmp"
  out="$(panel_artisan tinker --no-interaction --execute="require '$tmp';" 2>&1)" || rc=$?
  rm -f "$tmp"
  echo "$out"
  return $rc
}

# Geheugen en schijf van deze machine, met wat marge voor het OS
node_sizing() {
  local mem disk
  mem="$(free -m 2>/dev/null | awk '/^Mem:/{print $2}' || echo 4096)"
  disk="$(df -m /var/lib 2>/dev/null | awk 'NR==2{print $4}' || echo 51200)"
  # zelf ingevuld in de webinstaller? dan die waarde houden
  if [ -z "${NODE_MEM_MB:-}" ]; then
    NODE_MEM_MB=$(( mem - 1024 ))
    if [ "$NODE_MEM_MB" -lt 1024 ]; then NODE_MEM_MB=1024; fi
  fi
  if [ -z "${NODE_DISK_MB:-}" ]; then
    NODE_DISK_MB=$(( disk - 5120 ))
    if [ "$NODE_DISK_MB" -lt 10240 ]; then NODE_DISK_MB=10240; fi
  fi
}

# IP waar Wings op luistert (het interface-IP) en het IP dat klanten zien
node_ips() {
  NODE_BIND_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  NODE_PUBLIC_IP="$(detect_ip)"
  [ -n "$NODE_BIND_IP" ] || NODE_BIND_IP="$NODE_PUBLIC_IP"
  [ -n "$NODE_PUBLIC_IP" ] || NODE_PUBLIC_IP="$NODE_BIND_IP"
}

# Database host in het panel zetten (alleen als het panel op deze machine staat)
register_dbhost_in_panel() {
  info "Database host '${DBHOST_NAME}' registreren in het panel"
  local php out
  php="\$data = ['name' => '${DBHOST_NAME}','host' => '${DBHOST_FQDN}', 'port' => 3306, 'username' => '${DBADMIN_USER}', 'password' => '${DBADMIN_PASS}', 'node_id' => null];
if (class_exists(\\Pterodactyl\\Actions\\Databases\\CreateDatabaseHost::class)) {
    \$h = app(\\Pterodactyl\\Actions\\Databases\\CreateDatabaseHost::class)->create(\$data);
} else {
    \$h = app(\\Pterodactyl\\Services\\Databases\\Hosts\\HostCreationService::class)->handle(\$data);
}
echo 'WH_DBHOST_ID=' . \$h->id . PHP_EOL;"
  if out="$(panel_php "$php")" && echo "$out" | grep -q 'WH_DBHOST_ID='; then
    DBHOST_REGISTERED=1
    ok "Database host staat in het panel (id $(echo "$out" | grep -oP 'WH_DBHOST_ID=\K[0-9]+'))"
  else
    warn "Database host kon niet automatisch worden toegevoegd. Je doet dit straks handmatig."
    echo "$out" | tail -n 5 | sed 's/^/    /'
  fi
}

# Allocaties toevoegen aan een node, via het panel zelf
add_allocations_local() {
  local node_id="$1" php out ports_php
  [ -n "${ALLOC_PORTS:-}" ] || return 0
  ports_php="$(echo "$ALLOC_PORTS" | tr ',' '\n' | sed "s/.*/'&'/" | paste -sd, -)"
  info "Allocaties ${ALLOC_PORTS} toevoegen op ${NODE_BIND_IP}"
  php="\$node = \\Pterodactyl\\Models\\Node::findOrFail(${node_id});
\$data = ['allocation_ip' => '${NODE_BIND_IP}', 'allocation_ports' => [${ports_php}]];
if ('${NODE_BIND_IP}' !== '${NODE_PUBLIC_IP}') { \$data['allocation_alias'] = '${NODE_PUBLIC_IP}'; }
if (class_exists(\\Pterodactyl\\Actions\\Allocations\\CreateAllocations::class)) {
    app(\\Pterodactyl\\Actions\\Allocations\\CreateAllocations::class)->create(\$node, \$data);
} else {
    app(\\Pterodactyl\\Services\\Allocations\\AssignmentService::class)->handle(\$node, \$data);
}
echo 'WH_ALLOC_OK' . PHP_EOL;"
  if out="$(panel_php "$php")" && echo "$out" | grep -q 'WH_ALLOC_OK'; then
    ok "Allocaties toegevoegd"
    ALLOC_DONE=1
  else
    warn "Allocaties konden niet worden toegevoegd, voeg ze toe via Admin > Nodes > Allocation."
    echo "$out" | tail -n 3 | sed 's/^/    /'
  fi
}

# Wings starten en kijken of hij bij het panel komt
start_wings() {
  info "Wings starten"
  systemctl restart wings
  local i
  for i in 1 2 3 4 5 6; do
    sleep 2
    systemctl is-active --quiet wings && break
  done
  if systemctl is-active --quiet wings; then
    ok "Wings draait"
    NODE_REGISTERED=1
  else
    warn "Wings is niet gestart. Kijk in: journalctl -u wings -n 50"
  fi
}

# Panel staat op deze machine: alles via artisan
register_node_local() {
  local out loc_id node_id scheme="https"
  [ $USE_SSL -eq 1 ] || scheme="http"
  node_sizing; node_ips

  info "Locatie '${LOCATION_SHORT}' aanmaken"
  out="$(panel_artisan p:location:make --short="$LOCATION_SHORT" --long="$LOCATION_LONG" --no-interaction 2>&1)" || true
  loc_id="$(echo "$out" | grep -oiE 'id of [0-9]+' | grep -oE '[0-9]+' | head -n1 || true)"
  if [ -z "$loc_id" ]; then
    # bestaat hij al? dan het id opzoeken
    loc_id="$(panel_php "echo 'WH_LOC=' . (\\Pterodactyl\\Models\\Location::where('short', '${LOCATION_SHORT}')->value('id') ?? '') . PHP_EOL;" | grep -oP 'WH_LOC=\K[0-9]+' || true)"
  fi
  if [ -z "$loc_id" ]; then
    warn "Locatie kon niet worden aangemaakt. Node meld je straks handmatig aan."
    echo "$out" | tail -n 3 | sed 's/^/    /'
    return 0
  fi
  ok "Locatie id $loc_id"

  info "Node '${NODE_NAME}' aanmaken (${NODE_MEM_MB} MB geheugen, ${NODE_DISK_MB} MB schijf)"
  out="$(panel_artisan p:node:make \
    --name="$NODE_NAME" \
    --description="Aangemaakt door de ${COMPANY} installer" \
    --locationId="$loc_id" \
    --fqdn="$FQDN" \
    --public=1 \
    --scheme="$scheme" \
    --proxy=0 \
    --maintenance=0 \
    --maxMemory="$NODE_MEM_MB" \
    --overallocateMemory=0 \
    --maxDisk="$NODE_DISK_MB" \
    --overallocateDisk=0 \
    --uploadSize=100 \
    --daemonListeningPort="$NODE_DAEMON_PORT" \
    --daemonSFTPPort="$NODE_SFTP_PORT" \
    --daemonBase=/var/lib/pterodactyl/volumes \
    --no-interaction 2>&1)" || true
  node_id="$(echo "$out" | grep -oiE 'id of [0-9]+' | grep -oE '[0-9]+' | head -n1 || true)"
  if [ -z "$node_id" ]; then
    warn "Node kon niet worden aangemaakt. Node meld je straks handmatig aan."
    echo "$out" | tail -n 5 | sed 's/^/    /'
    return 0
  fi
  NODE_ID="$node_id"
  ok "Node id $node_id"

  info "Wings-config ophalen"
  if panel_artisan p:node:configuration "$node_id" --format=yaml --no-interaction > /etc/pterodactyl/config.yml 2>/dev/null \
     && grep -q '^token' /etc/pterodactyl/config.yml; then
    chmod 600 /etc/pterodactyl/config.yml
    ok "Config staat in /etc/pterodactyl/config.yml"
  else
    rm -f /etc/pterodactyl/config.yml
    warn "Config ophalen mislukt. Kopieer hem handmatig uit Admin > Nodes > ${NODE_NAME} > Configuration."
    return 0
  fi

  add_allocations_local "$node_id"
  start_wings
}

# Panel staat elders: alles via de Application API
panel_api() {
  # panel_api <method> <pad> [json]
  local method="$1" path="$2" body="${3:-}"
  curl -fsS --max-time 30 -X "$method" "${PANEL_URL}/api/application${path}" \
    -H "Authorization: Bearer ${PANEL_API_KEY}" \
    -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    ${body:+-d "$body"} 2>&1
}

register_node_api() {
  local out loc_id="${LOCATION_ID:-}" node_id scheme="https" fqdn ports_json
  [ $USE_SSL -eq 1 ] || scheme="http"
  node_sizing; node_ips
  fqdn="${NODE_FQDN:-$NODE_PUBLIC_IP}"

  info "Verbinding met ${PANEL_URL} testen"
  if ! panel_api GET "/locations?per_page=1" >/dev/null; then
    warn "Kan het panel niet bereiken met deze API key. Node meld je straks handmatig aan."
    return 0
  fi

  if [ -z "$loc_id" ]; then
    info "Locatie '${LOCATION_SHORT}' aanmaken"
    out="$(panel_api POST "/locations" "{\"short\":\"${LOCATION_SHORT}\",\"long\":\"${LOCATION_LONG}\"}")" || true
    loc_id="$(echo "$out" | grep -oP '"id":\s*\K[0-9]+' | head -n1 || true)"
    if [ -z "$loc_id" ]; then
      # misschien bestaat hij al
      loc_id="$(panel_api GET "/locations?per_page=100" | tr '{' '\n' | grep "\"short\":\"${LOCATION_SHORT}\"" | grep -oP '"id":\s*\K[0-9]+' | head -n1 || true)"
    fi
    if [ -z "$loc_id" ]; then
      warn "Locatie kon niet worden aangemaakt. Node meld je straks handmatig aan."
      echo "$out" | tail -c 300 | sed 's/^/    /'; echo
      return 0
    fi
  fi
  ok "Locatie id $loc_id"

  info "Node '${NODE_NAME}' aanmaken (${NODE_MEM_MB} MB geheugen, ${NODE_DISK_MB} MB schijf)"
  out="$(panel_api POST "/nodes" "{
    \"name\":\"${NODE_NAME}\",
    \"description\":\"Aangemaakt door de ${COMPANY} installer\",
    \"location_id\":${loc_id},
    \"fqdn\":\"${fqdn}\",
    \"scheme\":\"${scheme}\",
    \"behind_proxy\":false,
    \"public\":true,
    \"maintenance_mode\":false,
    \"memory\":${NODE_MEM_MB},
    \"memory_overallocate\":0,
    \"disk\":${NODE_DISK_MB},
    \"disk_overallocate\":0,
    \"upload_size\":100,
    \"daemon_listen\":${NODE_DAEMON_PORT},
    \"daemon_sftp\":${NODE_SFTP_PORT},
    \"daemon_base\":\"/var/lib/pterodactyl/volumes\"
  }")" || true
  node_id="$(echo "$out" | grep -oP '"id":\s*\K[0-9]+' | head -n1 || true)"
  if [ -z "$node_id" ]; then
    warn "Node kon niet worden aangemaakt. Node meld je straks handmatig aan."
    echo "$out" | tail -c 400 | sed 's/^/    /'; echo
    return 0
  fi
  NODE_ID="$node_id"
  ok "Node id $node_id"

  info "Wings-config ophalen"
  # 'wings configure' haalt de config op met dezelfde API key en schrijft hem weg
  if /usr/local/bin/wings configure --panel-url "$PANEL_URL" --token "$PANEL_API_KEY" --node "$node_id" --override >/dev/null 2>&1 \
     && grep -q '^token' /etc/pterodactyl/config.yml 2>/dev/null; then
    chmod 600 /etc/pterodactyl/config.yml
    ok "Config staat in /etc/pterodactyl/config.yml"
  else
    warn "Config ophalen mislukt. Kopieer hem handmatig uit Admin > Nodes > ${NODE_NAME} > Configuration."
    return 0
  fi

  if [ -n "${ALLOC_PORTS:-}" ]; then
    info "Allocaties ${ALLOC_PORTS} toevoegen op ${NODE_BIND_IP}"
    ports_json="$(echo "$ALLOC_PORTS" | tr ',' '\n' | sed 's/.*/"&"/' | paste -sd, -)"
    if [ "$NODE_BIND_IP" != "$NODE_PUBLIC_IP" ]; then
      out="$(panel_api POST "/nodes/${node_id}/allocations" "{\"ip\":\"${NODE_BIND_IP}\",\"alias\":\"${NODE_PUBLIC_IP}\",\"ports\":[${ports_json}]}")" && ALLOC_DONE=1 || true
    else
      out="$(panel_api POST "/nodes/${node_id}/allocations" "{\"ip\":\"${NODE_BIND_IP}\",\"ports\":[${ports_json}]}")" && ALLOC_DONE=1 || true
    fi
    [ "${ALLOC_DONE:-0}" -eq 1 ] && ok "Allocaties toegevoegd" || warn "Allocaties konden niet worden toegevoegd, doe dit via Admin > Nodes > Allocation."
  fi

  start_wings
}

register_node() {
  if want_panel; then
    register_node_local
    # artisan draaide als root, dus cache- en logbestanden weer van de webserver maken
    chown -R "${WEB_USER}:${WEB_USER}" "$PANEL_DIR"
  else
    register_node_api
  fi
}

# ----------------------------------------------------------------------------
#  Firewall
# ----------------------------------------------------------------------------
setup_firewall() {
  info "Firewall instellen"
  local opened="22" range

  # Poortbereik 25565-25600 -> ufw wil 25565:25600, firewalld 25565-25600
  local -a ranges=()
  if want_node && [ -n "${ALLOC_PORTS:-}" ]; then
    IFS=',' read -r -a ranges <<< "$ALLOC_PORTS"
  fi

  if [ "$OS_FAMILY" = "debian" ]; then
    pkg_install ufw
    ufw allow 22/tcp >/dev/null
    # De webinstaller zelf moet bereikbaar blijven tot hij klaar is
    if [ -n "${WEBINSTALLER_PORT:-}" ]; then
      ufw allow "${WEBINSTALLER_PORT}/tcp" >/dev/null
    fi
    if want_panel; then
      ufw allow 80/tcp  >/dev/null
      ufw allow 443/tcp >/dev/null
      opened="$opened, 80, 443"
    elif [ -n "${NODE_FQDN:-}" ]; then
      # certbot renewal heeft poort 80 nodig
      ufw allow 80/tcp >/dev/null
      opened="$opened, 80"
    fi
    if want_node; then
      ufw allow "${NODE_DAEMON_PORT}/tcp" >/dev/null
      ufw allow "${NODE_SFTP_PORT}/tcp" >/dev/null
      opened="$opened, ${NODE_DAEMON_PORT}, ${NODE_SFTP_PORT}"
      for range in "${ranges[@]}"; do
        ufw allow "${range/-/:}/tcp" >/dev/null
        ufw allow "${range/-/:}/udp" >/dev/null
        opened="$opened, $range"
      done
    fi
    if [ "$SETUP_DBHOST" -eq 1 ]; then
      ufw allow 3306/tcp >/dev/null
      opened="$opened, 3306"
    fi
    ufw --force enable >/dev/null
    ok "UFW actief ($opened)"
  else
    pkg_install firewalld
    systemctl enable --now firewalld >/dev/null 2>&1 || true
    firewall-cmd --permanent --add-service=ssh >/dev/null
    if [ -n "${WEBINSTALLER_PORT:-}" ]; then
      firewall-cmd --add-port="${WEBINSTALLER_PORT}/tcp" >/dev/null 2>&1 || true
    fi
    if want_panel; then
      firewall-cmd --permanent --add-service=http  >/dev/null
      firewall-cmd --permanent --add-service=https >/dev/null
      opened="$opened, 80, 443"
    elif [ -n "${NODE_FQDN:-}" ]; then
      firewall-cmd --permanent --add-service=http >/dev/null
      opened="$opened, 80"
    fi
    if want_node; then
      firewall-cmd --permanent --add-port="${NODE_DAEMON_PORT}/tcp" >/dev/null
      firewall-cmd --permanent --add-port="${NODE_SFTP_PORT}/tcp" >/dev/null
      # Pterodactyl docs: docker netwerk van Wings in de trusted zone + masquerade
      firewall-cmd --permanent --zone=trusted --change-interface=pterodactyl0 >/dev/null 2>&1 || true
      firewall-cmd --permanent --zone=trusted --add-masquerade >/dev/null 2>&1 || true
      opened="$opened, ${NODE_DAEMON_PORT}, ${NODE_SFTP_PORT}"
      for range in "${ranges[@]}"; do
        firewall-cmd --permanent --add-port="${range}/tcp" >/dev/null
        firewall-cmd --permanent --add-port="${range}/udp" >/dev/null
        opened="$opened, $range"
      done
    fi
    if [ "$SETUP_DBHOST" -eq 1 ]; then
      firewall-cmd --permanent --add-port=3306/tcp >/dev/null
      opened="$opened, 3306"
    fi
    firewall-cmd --reload >/dev/null
    # --reload gooit tijdelijke regels weg, dus de webinstaller opnieuw openzetten
    if [ -n "${WEBINSTALLER_PORT:-}" ]; then
      firewall-cmd --add-port="${WEBINSTALLER_PORT}/tcp" >/dev/null 2>&1 || true
    fi
    ok "firewalld actief ($opened)"
  fi

  if want_node && [ "${#ranges[@]}" -eq 0 ]; then
    warn "Poorten voor de gameservers zelf moet je er zelf bij zetten,"
    if [ "$OS_FAMILY" = "debian" ]; then
      warn "bv. 'ufw allow 25565:25600/tcp' of het bereik dat je node gebruikt."
    else
      warn "bv. 'firewall-cmd --permanent --add-port=25565-25600/tcp && firewall-cmd --reload'."
    fi
  fi
}

# ----------------------------------------------------------------------------
#  Afsluiten
# ----------------------------------------------------------------------------
finish() {
  local proto="https" php_full=""
  [ $USE_SSL -eq 0 ] && proto="http"
  if want_panel; then
    php_full="$(php -r 'echo PHP_VERSION;' 2>/dev/null || echo "$PHP_VERSION")"
  fi

  {
    echo "WiredHosting - Pterodactyl installatie"
    echo "Copyright (c) ${COPYRIGHT_YEAR} ${COPYRIGHT_OWNER}. Alle rechten voorbehouden."
    echo
    echo "Modus           : ${MODE_LABEL}"
    echo "OS              : ${PRETTY_NAME}"
    echo "Geinstalleerd op: $(date '+%Y-%m-%d %H:%M:%S')"
    if want_panel; then
      echo
      echo "Panel versie    : ${PANEL_VERSION}"
      echo "PHP versie      : ${php_full}$([ "${PHP_UNPATCHED:-0}" -eq 1 ] && echo '  (LET OP: nog niet gepatcht voor PHP2Shell)')"
      echo "Panel URL       : ${proto}://${FQDN}"
      echo "SSL             : $(ssl_label)"
      echo "Admin gebruiker : ${ADMIN_USER}"
      echo "Admin e-mail    : ${ADMIN_EMAIL}"
      echo "Admin wachtwoord: ${ADMIN_PASS}"
      echo
      echo "Panel database  : ${DB_NAME}"
      echo "DB gebruiker    : ${DB_USER}@127.0.0.1"
      echo "DB wachtwoord   : ${DB_PASS}"
      echo
      echo "Panel map       : ${PANEL_DIR}"
      echo "Webserver user  : ${WEB_USER}"
      echo "Nginx config    : ${NGINX_CONF}"
      echo "PHP-FPM socket  : ${PHP_FPM_SOCK}"
      echo "Queue service   : pteroq.service"
    fi
    if [ "${WINGS_NOTE:-0}" -eq 1 ]; then
      echo
      echo "Wings versie    : ${WINGS_VERSION}"
      echo "Wings config    : /etc/pterodactyl/config.yml"
      if [ -n "${NODE_ID:-}" ]; then
        echo "Node in panel   : ${NODE_NAME} (id ${NODE_ID})$([ "${NODE_REGISTERED:-0}" -eq 1 ] && echo ', Wings draait' || echo ', Wings nog niet gestart')"
      fi
      if [ -n "${NODE_FQDN:-}" ]; then
        echo "Node domein     : ${NODE_FQDN}"
      fi
    fi
    if [ "${DBHOST_NOTE:-0}" -eq 1 ]; then
      echo
      echo "--- Database host (invullen onder Admin > Databases > Create New) ---"
      echo "Name     : ${DBHOST_NAME}"
      echo "Host     : ${DBHOST_FQDN}"
      echo "Port     : 3306"
      echo "Username : ${DBADMIN_USER}"
      echo "Password : ${DBADMIN_PASS}"
      echo "(account bestaat voor: ${DBADMIN_HOSTS:-$DBADMIN_HOST})"
      if [ "${DBHOST_REGISTERED:-0}" -eq 1 ]; then
        echo "Status   : staat al in het panel"
      fi
    fi
  } > "$CRED_FILE"
  chmod 600 "$CRED_FILE"

  if want_panel; then mark "RESULT|panel_url|${proto}://${FQDN}"; fi
  mark "RESULT|cred_file|${CRED_FILE}"
  mark "SUMMARY"
  echo
  echo -e "${GREEN}${BOLD}  Installatie voltooid${NC}"
  echo "-----------------------------------------------"
  echo -e "  Modus      : ${MODE_LABEL}"
  if want_panel; then
    echo -e "  Panel      : ${BOLD}${proto}://${FQDN}${NC}"
    echo -e "  Versie     : ${PANEL_VERSION}"
    echo -e "  PHP        : ${php_full}"
    echo -e "  Gebruiker  : ${ADMIN_USER}"
    if [ "${GENERATED_PASS:-0}" -eq 1 ]; then
      echo -e "  Wachtwoord : ${BOLD}${ADMIN_PASS}${NC}"
    else
      echo -e "  Wachtwoord : (zoals ingevoerd)"
    fi
  fi
  if [ "${WINGS_NOTE:-0}" -eq 1 ]; then
    echo -e "  Wings      : ${WINGS_VERSION}"
  fi
  echo -e "  Gegevens   : ${CRED_FILE}"
  echo "-----------------------------------------------"

  if [ "${PHP_UNPATCHED:-0}" -eq 1 ]; then
    echo
    echo -e "${RED}${BOLD}  PHP is nog niet gepatcht voor PHP2Shell.${NC}"
    echo "  De fix (PHP $(php_patched_min "$PHP_VERSION")) stond nog niet in de repository. Draai zodra die er is:"
    echo "    ${INSTALLER_CMD}"
    echo "  en kies 'Alleen PHP updaten'."
    echo "  Tot die tijd is het panel kwetsbaar voor unauthenticated RCE."
  fi

  if [ "${PANEL_MAJOR:-1}" != "1" ] && want_panel; then
    echo
    echo -e "${YELLOW}Pterodactyl 2.0 (beta):${NC}"
    echo "  Nests zijn vervangen door tags, de nests endpoints van de Application API"
    echo "  bestaan niet meer. Check je billing module (WHMCS module is bijgewerkt)."
    echo "  Updaten binnen 2.0: niet met p:upgrade, volg ${DOCS_URL_V2}/panel/updating"
  fi

  if [ "$OS_FAMILY" = "rhel" ] && want_node && selinux_active; then
    echo
    echo -e "${YELLOW}SELinux en Wings:${NC}"
    echo "  Geven containers AVC denials in /var/log/audit/audit.log? Verplaats dan de"
    echo "  Wings data naar /var/srv/containers/pterodactyl (zie de Pterodactyl docs"
    echo "  voor Enterprise Linux) of zet SELinux tijdelijk op permissive om te testen."
  fi

  if [ "${DBHOST_NOTE:-0}" -eq 1 ]; then
    echo
    if [ "${DBHOST_REGISTERED:-0}" -eq 1 ]; then
      echo -e "${GREEN}Database host '${DBHOST_NAME}' staat in het panel.${NC}"
      echo "  Maak je een database aan voor een server, zet 'Connections from' dan op %,"
      echo "  dan kan de klant vanaf elk IP verbinden."
    else
      echo -e "${YELLOW}Database host afmaken in het panel:${NC}"
      echo "  Admin > Databases > Create New Database Host"
      echo "    Name     : ${DBHOST_NAME}"
      echo "    Host     : ${DBHOST_FQDN}"
      echo "    Port     : 3306"
      echo "    Username : ${DBADMIN_USER}"
      echo "    Password : staat in ${CRED_FILE}"
      echo
      echo "  Bij een database per server zet je 'Connections from' op % ,"
      echo "  dan kan de klant vanaf elk IP verbinden."
      echo "  Test de verbinding eerst: mysql -h ${DBHOST_FQDN} -u ${DBADMIN_USER} -p -e 'SELECT 1;'"
    fi
    echo
    echo "  Staat ${DBHOST_FQDN} achter de Cloudflare proxy? Zet dat record op"
    echo "  DNS only, want 3306 gaat niet door de proxy heen."
  fi

  if [ "${WINGS_NOTE:-0}" -eq 1 ]; then
    echo
    if [ "${NODE_REGISTERED:-0}" -eq 1 ]; then
      echo -e "${GREEN}Node '${NODE_NAME}' is aangemeld en Wings draait.${NC}"
      echo "  Node id ${NODE_ID}, config in /etc/pterodactyl/config.yml."
      echo "  Binnen een minuut staat de node op groen in Admin > Nodes."
      if [ "${ALLOC_DONE:-0}" -eq 1 ]; then
        echo "  Allocaties ${ALLOC_PORTS} staan klaar op ${NODE_BIND_IP}."
      else
        echo "  Voeg nog allocaties (poorten) toe onder Admin > Nodes > ${NODE_NAME} > Allocation."
      fi
      echo "  Logs bekijken: journalctl -u wings -f"
    else
      echo -e "${YELLOW}Node afmaken:${NC}"
      if [ -n "${NODE_ID:-}" ]; then
        echo "  De node (id ${NODE_ID}) staat al in het panel, maar Wings draait nog niet."
        echo "  1. Open Admin > Nodes > ${NODE_NAME} > Configuration."
        echo "  2. Plak die config in /etc/pterodactyl/config.yml"
        echo "  3. systemctl start wings"
      else
        if want_panel; then
          echo "  1. Ga in dit panel naar Admin > Locations en maak een locatie aan."
          echo "  2. Admin > Nodes > Create New, kies die locatie."
        else
          echo "  1. Ga in je bestaande panel naar Admin > Locations (of gebruik er een)."
          echo "  2. Admin > Nodes > Create New, met FQDN ${NODE_FQDN:-van deze server}."
          if [ -n "${NODE_FQDN:-}" ] && [ $USE_SSL -eq 1 ]; then
            echo "     Zet 'Communicate Over SSL' aan, het certificaat staat klaar."
          elif [ -z "${NODE_FQDN:-}" ]; then
            echo "     Zonder domein en certificaat moet je SSL uitzetten op de node."
          fi
        fi
        echo "  3. Open het tabblad Configuration van de node."
        echo "  4. Plak die config in /etc/pterodactyl/config.yml"
        echo "  5. systemctl start wings"
      fi
      echo
      echo "  Daarna meldt deze machine zich vanzelf bij het panel."
      echo "  Logs bekijken: journalctl -u wings -f"
    fi
  fi

  if [ "${NEEDS_REBOOT:-0}" -eq 1 ]; then
    echo
    warn "Herstart de server om swap accounting te activeren."
  fi
  echo
  echo -e "Documentatie: ${BLUE}${DOCS_URL}${NC}"
  echo -e "Support     : ${BLUE}https://wiredhosting.nl${NC}"
  echo
  echo -e "Copyright (c) ${COPYRIGHT_YEAR} ${COPYRIGHT_OWNER}. Alle rechten voorbehouden."
  echo -e "Dit installatiescript is eigendom van ${COPYRIGHT_OWNER} en mag niet"
  echo -e "worden overgenomen, aangepast of verspreid zonder schriftelijke"
  echo -e "toestemming. Contact: ${COPYRIGHT_CONTACT}"
  echo
}

# ----------------------------------------------------------------------------
#  Stappen
# ----------------------------------------------------------------------------
step_dbhost()       { install_mariadb; setup_dbhost; }
step_dbhost_panel() { register_dbhost_in_panel; chown -R "${WEB_USER}:${WEB_USER}" "$PANEL_DIR"; }

STEP_LABELS=()
STEP_FUNCS=()
add_step() { STEP_LABELS+=("$1"); STEP_FUNCS+=("$2"); }

plan_steps() {
  add_step "Basispakketten installeren" install_base
  if want_panel; then
    add_step "PHP ${PHP_VERSION}, MariaDB, nginx en Redis installeren" install_deps
    add_step "Database '${DB_NAME}' aanmaken" setup_db
  fi
  if [ "$SETUP_DBHOST" -eq 1 ]; then
    add_step "Database host voor klanten" step_dbhost
  fi
  if want_panel; then
    add_step "Panel ${PANEL_VERSION} installeren" install_panel
    add_step "Cronjob en queue worker" setup_cron_queue
    add_step "Webserver en SSL" setup_nginx
    if [ "$SETUP_DBHOST" -eq 1 ]; then
      add_step "Database host in het panel zetten" step_dbhost_panel
    fi
  fi
  if want_node; then
    if ! want_panel && [ "$USE_SSL" -eq 1 ] && [ -n "${NODE_FQDN:-}" ]; then
      add_step "SSL certificaat voor de node" setup_node_ssl
    fi
    add_step "Docker en Wings ${WINGS_VERSION} installeren" install_wings
  fi
  # Firewall voor het aanmelden, zodat de daemon poort open staat als Wings start
  if [ "$SETUP_FW" -eq 1 ]; then
    add_step "Firewall instellen" setup_firewall
  fi
  if want_node && [ "$AUTO_NODE" -eq 1 ]; then
    add_step "Node '${NODE_NAME}' aanmelden bij het panel" register_node
  fi
  add_step "Afronden" finish
  STEP_TOTAL=${#STEP_LABELS[@]}
  mark "PLAN|$(IFS='|'; echo "${STEP_LABELS[*]}")"
}

run_steps() {
  local i
  for i in "${!STEP_FUNCS[@]}"; do
    step "${STEP_LABELS[$i]}"
    "${STEP_FUNCS[$i]}"
  done
}

# ----------------------------------------------------------------------------
#  Webinstaller: foutmeldingen en opruimen
# ----------------------------------------------------------------------------
LAST_CMD=""
LAST_LINE=""
on_exit() {
  local rc=$1
  if [ "$MACHINE" -eq 1 ]; then
    if [ "$rc" -eq 0 ]; then
      echo "@@DONE"
    elif [ "${FAIL_SENT:-0}" -eq 0 ]; then
      echo "@@FAIL|Onverwachte fout bij: ${LAST_CMD:-onbekend} (regel ${LAST_LINE:-?})"
    fi
    echo "@@EXIT|$rc"
  fi
  # de config bevat wachtwoorden en de API key
  if [ "$RUN_MODE" = "config" ] && [ -n "$CONFIG_FILE" ]; then rm -f "$CONFIG_FILE"; fi
}

usage() {
  echo "Gebruik: bash installer.sh [--config bestand] [--check] [--info]"
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --config) CONFIG_FILE="${2:-}"; [ "$RUN_MODE" = "check" ] || RUN_MODE="config"; shift ;;
      --check)  RUN_MODE="check" ;;
      --info)   RUN_MODE="info" ;;
      -h|--help) usage; exit 0 ;;
      *) usage; exit 1 ;;
    esac
    shift
  done
}

# ----------------------------------------------------------------------------
#  Main
# ----------------------------------------------------------------------------
parse_args "$@"

case "$RUN_MODE" in
  info)
    print_info
    exit 0
    ;;
  check)
    preflight >/dev/null
    load_config
    validate_config
    [ "$CFG_ERRORS" -eq 0 ] && echo "@@OK"
    exit 0
    ;;
  config)
    MACHINE=1
    set -E
    trap 'LAST_CMD="$BASH_COMMAND"; LAST_LINE="$LINENO"' ERR
    trap 'on_exit $?' EXIT
    banner
    preflight
    load_config
    validate_config
    [ "$CFG_ERRORS" -eq 0 ] || fail "De config klopt niet, zie de meldingen hierboven."
    ;;
  *)
    banner
    preflight
    ask
    ;;
esac

if [ "$INSTALL_MODE" = "phpfix" ]; then
  STEP_TOTAL=1
  mark "PLAN|PHP bijwerken"
  step "PHP bijwerken"
  patch_php
  mark "SUMMARY"
  exit 0
fi

finalize_config
resolve_versions
show_summary
plan_steps
run_steps
