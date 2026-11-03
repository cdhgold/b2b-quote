#!/bin/bash
# =============================================================================
# cafe24 가상서버 초기 구성 + 하드닝 (Spec 7.1 ~ 7.4, M0)
# 대상: Rocky Linux 9 / Ubuntu 22.04 LTS. root 로 1회 실행 (재실행해도 안전하게 작성).
#
# 사용법 (저장소의 deploy/ 디렉터리를 서버로 복사한 뒤):
#   sudo DOMAIN=quote.example.co.kr \
#        ADMIN_USER=admin ADMIN_IPS="203.0.113.10" \
#        SSH_PORT=22022 CERT_EMAIL=ops@example.co.kr \
#        DEPLOY_PUBKEY="ssh-ed25519 AAAA... github-actions-deploy" \
#        bash deploy/server/bootstrap.sh
#
# 선택 변수:
#   OPS_DOMAIN        운영자 서브도메인 (기본 ops.$DOMAIN)
#   DEPLOY_FROM_GITHUB=1  GitHub 호스티드 러너에서 SSH 배포를 받기 위해 SSH 포트를 전체에 열고,
#                     sshd 수준에서 deploy 계정(강제명령 키)만 외부 접속 허용, 관리자 계정은
#                     ADMIN_IPS 에서만 허용. 0 이면 방화벽에서도 ADMIN_IPS 만 허용
#                     (이 경우 self-hosted runner 또는 VPN 경유 배포 필요). 기본 1.
#   SKIP_TLS=1        DNS 가 아직 서버를 가리키지 않을 때 인증서 발급을 건너뜀 (나중에 다시 실행)
#
# 주의: SSH 설정을 바꾸므로, 실행 후 "새 터미널에서" 새 포트·키로 접속되는지 확인하기 전까지
#       기존 세션을 닫지 마세요.
# =============================================================================
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # deploy/

: "${DOMAIN:?DOMAIN 필요}"
: "${ADMIN_USER:?ADMIN_USER 필요 (키가 등록된 기존 관리자 계정)}"
: "${ADMIN_IPS:?ADMIN_IPS 필요 (공백 구분 고정 IP/CIDR)}"
: "${SSH_PORT:?SSH_PORT 필요 (22 가 아닌 포트)}"
: "${CERT_EMAIL:?CERT_EMAIL 필요}"
: "${DEPLOY_PUBKEY:?DEPLOY_PUBKEY 필요 (GitHub Actions 배포 전용 공개키)}"
OPS_DOMAIN="${OPS_DOMAIN:-ops.$DOMAIN}"
DEPLOY_FROM_GITHUB="${DEPLOY_FROM_GITHUB:-1}"
SKIP_TLS="${SKIP_TLS:-0}"
DB_NAME=quote_market

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[WARN] %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[ERROR] %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "root 로 실행하세요"
[[ "$SSH_PORT" =~ ^[0-9]+$ ]] && [ "$SSH_PORT" -ne 22 ] && [ "$SSH_PORT" -lt 65536 ] || die "SSH_PORT 는 22 가 아닌 포트 번호"
[[ "$DEPLOY_PUBKEY" =~ ^ssh-(ed25519|rsa)\  ]] || die "DEPLOY_PUBKEY 형식 오류"
id "$ADMIN_USER" >/dev/null 2>&1 || die "관리자 계정 $ADMIN_USER 가 없습니다"
ADMIN_HOME="$(getent passwd "$ADMIN_USER" | cut -d: -f6)"
[ -s "$ADMIN_HOME/.ssh/authorized_keys" ] || die "$ADMIN_USER 의 ~/.ssh/authorized_keys 가 비어 있습니다 (잠김 방지를 위해 중단)"

# shellcheck disable=SC1091
. /etc/os-release
case "$ID" in
    rocky|rhel|almalinux) OS=rhel ;;
    ubuntu)               OS=ubuntu ;;
    *) die "지원하지 않는 OS: $ID" ;;
esac
log "OS: $PRETTY_NAME"

# -----------------------------------------------------------------------------
log "1. 시간대·시간 동기화 (Asia/Seoul, chrony)"
# -----------------------------------------------------------------------------
if [ "$OS" = rhel ]; then
    dnf -y install chrony tzdata
    systemctl enable --now chronyd
else
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -q
    apt-get -y install chrony tzdata
    systemctl enable --now chrony
fi
timedatectl set-timezone Asia/Seoul

# -----------------------------------------------------------------------------
log "2. 기본 패키지·자동 보안 업데이트"
# -----------------------------------------------------------------------------
if [ "$OS" = rhel ]; then
    dnf -y install epel-release
    dnf -y install curl tar gnupg2 openssl policycoreutils-python-utils firewalld \
                   fail2ban nginx certbot dnf-automatic
    sed -i 's/^upgrade_type.*/upgrade_type = security/; s/^apply_updates.*/apply_updates = yes/' /etc/dnf/automatic.conf
    systemctl enable --now dnf-automatic.timer
else
    apt-get -y install curl tar gnupg openssl ufw fail2ban nginx certbot unattended-upgrades apt-transport-https
    cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
    systemctl enable --now unattended-upgrades
fi

# -----------------------------------------------------------------------------
log "3. Java 17 (Eclipse Temurin)"
# -----------------------------------------------------------------------------
if ! java -version 2>&1 | grep -q '"17\.'; then
    if [ "$OS" = rhel ]; then
        cat > /etc/yum.repos.d/adoptium.repo <<'EOF'
[Adoptium]
name=Adoptium
baseurl=https://packages.adoptium.net/artifactory/rpm/rhel/$releasever/$basearch
enabled=1
gpgcheck=1
gpgkey=https://packages.adoptium.net/artifactory/api/gpg/key/public
EOF
        dnf -y install temurin-17-jdk
    else
        install -d -m 0755 /etc/apt/keyrings
        curl -fsSL https://packages.adoptium.net/artifactory/api/gpg/key/public | gpg --dearmor -o /etc/apt/keyrings/adoptium.gpg
        echo "deb [signed-by=/etc/apt/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb ${VERSION_CODENAME} main" \
            > /etc/apt/sources.list.d/adoptium.list
        apt-get update -q
        apt-get -y install temurin-17-jdk
    fi
fi
java -version 2>&1 | head -1

# -----------------------------------------------------------------------------
log "4. MariaDB 10.11 LTS"
# -----------------------------------------------------------------------------
if ! command -v mariadb >/dev/null 2>&1; then
    if [ "$OS" = rhel ]; then
        cat > /etc/yum.repos.d/mariadb.repo <<'EOF'
[mariadb]
name=MariaDB 10.11
baseurl=https://rpm.mariadb.org/10.11/rhel/$releasever/$basearch
gpgkey=https://rpm.mariadb.org/RPM-GPG-KEY-MariaDB
gpgcheck=1
module_hotfixes=1
EOF
        dnf -y install MariaDB-server MariaDB-client
    else
        install -d -m 0755 /etc/apt/keyrings
        curl -fsSL https://mariadb.org/mariadb_release_signing_key.pgp -o /etc/apt/keyrings/mariadb-keyring.pgp
        echo "deb [signed-by=/etc/apt/keyrings/mariadb-keyring.pgp] https://deb.mariadb.org/10.11/ubuntu ${VERSION_CODENAME} main" \
            > /etc/apt/sources.list.d/mariadb.list
        apt-get update -q
        apt-get -y install mariadb-server mariadb-client
    fi
fi
MYCNF_DIR=/etc/my.cnf.d; [ "$OS" = ubuntu ] && MYCNF_DIR=/etc/mysql/mariadb.conf.d
install -d -m 0755 "$MYCNF_DIR"
cat > "$MYCNF_DIR/90-app.cnf" <<'EOF'
[mysqld]
bind-address          = 127.0.0.1
skip-name-resolve
local-infile          = 0
character-set-server  = utf8mb4
collation-server      = utf8mb4_unicode_ci
default-time-zone     = '+09:00'
innodb_buffer_pool_size = 2G
max_connections       = 100
EOF
systemctl enable --now mariadb
systemctl restart mariadb

# -----------------------------------------------------------------------------
log "5. 계정·디렉터리"
# -----------------------------------------------------------------------------
id app    >/dev/null 2>&1 || useradd --system --home-dir /opt/app --shell /usr/sbin/nologin app
id deploy >/dev/null 2>&1 || useradd --create-home --shell /bin/bash deploy
passwd -l deploy >/dev/null

install -d -o root   -g app    -m 0750 /opt/app /opt/app/releases /etc/app
install -d -o root   -g root   -m 0755 /var/lib/app
install -d -o app    -g app    -m 0750 /var/lib/app/uploads /var/log/app
install -d -o deploy -g deploy -m 0700 /var/lib/app/incoming
install -d -o root   -g root   -m 0755 /var/www/letsencrypt

# -----------------------------------------------------------------------------
log "6. DB 보안 설정·계정 (mysql_secure_installation 상당 + 최소권한 계정, Spec 7.4)"
# -----------------------------------------------------------------------------
gen_pw() { openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 32; }
SECRETS=/etc/app/secrets.env
if [ ! -f "$SECRETS" ]; then
    APP_PW="$(gen_pw)"; MIG_PW="$(gen_pw)"
    # root 는 unix_socket 인증만 (원격·비밀번호 로그인 불가)
    mariadb <<SQL
DELETE FROM mysql.global_priv WHERE User = '';
DELETE FROM mysql.global_priv WHERE User = 'root' AND Host NOT IN ('localhost');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db = 'test' OR Db = 'test\\_%';
CREATE DATABASE IF NOT EXISTS ${DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'quote_app'@'127.0.0.1' IDENTIFIED BY '${APP_PW}';
CREATE USER IF NOT EXISTS 'quote_migration'@'127.0.0.1' IDENTIFIED BY '${MIG_PW}';
-- 앱: DML 만. 감사로그(audit_log)는 M1 마이그레이션에서 트리거로 UPDATE/DELETE 를 차단한다.
GRANT SELECT, INSERT, UPDATE, DELETE ON ${DB_NAME}.* TO 'quote_app'@'127.0.0.1';
-- 마이그레이션: 스키마 변경 + 이력 테이블 기록. 배포 시에만 사용.
GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, ALTER, DROP, INDEX, REFERENCES,
      CREATE VIEW, SHOW VIEW, TRIGGER, LOCK TABLES ON ${DB_NAME}.* TO 'quote_migration'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL
    umask 027
    cat > "$SECRETS" <<EOF
DB_URL=jdbc:mariadb://127.0.0.1:3306/${DB_NAME}
DB_APP_USERNAME=quote_app
DB_APP_PASSWORD=${APP_PW}
DB_MIGRATION_USERNAME=quote_migration
DB_MIGRATION_PASSWORD=${MIG_PW}
EOF
    umask 022
    unset APP_PW MIG_PW
fi
chown root:app "$SECRETS"; chmod 0640 "$SECRETS"

# -----------------------------------------------------------------------------
log "7. 배포 경로 (강제명령 SSH 키 + sudo 1개 명령, Spec 7.7)"
# -----------------------------------------------------------------------------
install -o root -g root -m 0755 "$SRC_DIR/bin/app-deploy-gate"   /usr/local/bin/app-deploy-gate
install -o root -g root -m 0700 "$SRC_DIR/bin/app-deploy"        /usr/local/sbin/app-deploy
install -o root -g root -m 0700 "$SRC_DIR/bin/cert-expiry-check" /usr/local/sbin/cert-expiry-check

install -d -o deploy -g deploy -m 0700 /home/deploy/.ssh
printf 'command="/usr/local/bin/app-deploy-gate",restrict %s\n' "$DEPLOY_PUBKEY" > /home/deploy/.ssh/authorized_keys
chown deploy:deploy /home/deploy/.ssh/authorized_keys; chmod 0600 /home/deploy/.ssh/authorized_keys

SUDOERS_TMP="$(mktemp)"
echo 'deploy ALL=(root) NOPASSWD: /usr/local/sbin/app-deploy' > "$SUDOERS_TMP"
visudo -cf "$SUDOERS_TMP" >/dev/null || die "sudoers 검증 실패"
install -o root -g root -m 0440 "$SUDOERS_TMP" /etc/sudoers.d/app-deploy; rm -f "$SUDOERS_TMP"

install -o root -g root -m 0644 "$SRC_DIR/systemd/app.service" /etc/systemd/system/app.service
systemctl daemon-reload
systemctl enable app   # 첫 배포(current.jar 생성) 이후에 기동됨

# -----------------------------------------------------------------------------
log "8. Nginx + TLS (Spec 6.5, 7.3)"
# -----------------------------------------------------------------------------
if [ "$OS" = rhel ]; then
    NGINX_USER=nginx; MODULES_INCLUDE='include /usr/share/nginx/modules/*.conf;'
    setsebool -P httpd_can_network_connect 1     # SELinux: Nginx → 127.0.0.1:8080/8081 프록시 허용
else
    NGINX_USER=www-data; MODULES_INCLUDE='include /etc/nginx/modules-enabled/*.conf;'
    rm -f /etc/nginx/sites-enabled/default
fi
[ -f /etc/nginx/nginx.conf.orig ] || cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.orig
sed -e "s|__NGINX_USER__|$NGINX_USER|" -e "s|__MODULES_INCLUDE__|$MODULES_INCLUDE|" \
    "$SRC_DIR/nginx/nginx.conf" > /etc/nginx/nginx.conf
rm -f /etc/nginx/conf.d/default.conf
install -d -m 0755 /etc/nginx/snippets
install -m 0644 "$SRC_DIR/nginx/snippets/tls.conf"   /etc/nginx/snippets/tls.conf
install -m 0644 "$SRC_DIR/nginx/snippets/proxy.conf" /etc/nginx/snippets/proxy.conf
{
    echo "# 운영자 서브도메인 IP 허용목록 (bootstrap.sh 생성)"
    for ip in $ADMIN_IPS; do echo "allow $ip;"; done
    echo "deny all;"
} > /etc/nginx/snippets/ops-allow.conf
install -m 0644 "$SRC_DIR/nginx/app-http.conf" /etc/nginx/conf.d/app-http.conf
nginx -t
systemctl enable --now nginx
systemctl reload nginx

if [ "$SKIP_TLS" != 1 ]; then
    if [ ! -d /etc/letsencrypt/live/app ]; then
        certbot certonly --webroot -w /var/www/letsencrypt --cert-name app \
            -d "$DOMAIN" -d "$OPS_DOMAIN" \
            --email "$CERT_EMAIL" --agree-tos --no-eff-email --non-interactive \
            --deploy-hook "systemctl reload nginx"
    fi
    sed -e "s|__DOMAIN__|$DOMAIN|g" -e "s|__OPS_DOMAIN__|$OPS_DOMAIN|g" \
        "$SRC_DIR/nginx/app-https.conf" > /etc/nginx/conf.d/app-https.conf
    nginx -t
    systemctl reload nginx
    # certbot 패키지의 자동 갱신 타이머 확인 + 만료 14일 전 경고
    systemctl enable --now certbot-renew.timer 2>/dev/null || systemctl enable --now certbot.timer 2>/dev/null || true
    echo "0 9 * * * root /usr/local/sbin/cert-expiry-check" > /etc/cron.d/cert-expiry-check
else
    warn "SKIP_TLS=1: 인증서 발급과 HTTPS 설정을 건너뜀. DNS 연결 후 SKIP_TLS 없이 다시 실행하세요."
fi

# -----------------------------------------------------------------------------
log "9. 방화벽 (80/443 전체, SSH 제한, Spec 7.2)"
# -----------------------------------------------------------------------------
if [ "$OS" = rhel ]; then
    semanage port -l | grep -qE "^ssh_port_t.*\b${SSH_PORT}\b" || semanage port -a -t ssh_port_t -p tcp "$SSH_PORT"
    systemctl enable --now firewalld
    firewall-cmd --permanent --remove-service=ssh >/dev/null 2>&1 || true
    firewall-cmd --permanent --remove-service=cockpit >/dev/null 2>&1 || true
    firewall-cmd --permanent --add-service=http --add-service=https >/dev/null
    if [ "$DEPLOY_FROM_GITHUB" = 1 ]; then
        firewall-cmd --permanent --add-port="${SSH_PORT}/tcp" >/dev/null
    else
        for ip in $ADMIN_IPS; do
            firewall-cmd --permanent --add-rich-rule="rule family=ipv4 source address=$ip port port=$SSH_PORT protocol=tcp accept" >/dev/null
        done
    fi
    firewall-cmd --reload
else
    ufw --force reset >/dev/null
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow 80/tcp
    ufw allow 443/tcp
    if [ "$DEPLOY_FROM_GITHUB" = 1 ]; then
        ufw allow "${SSH_PORT}/tcp"
    else
        for ip in $ADMIN_IPS; do ufw allow from "$ip" to any port "$SSH_PORT" proto tcp; done
    fi
    ufw --force enable
fi

# -----------------------------------------------------------------------------
log "10. fail2ban (SSH, Nginx)"
# -----------------------------------------------------------------------------
SSHD_BACKEND=auto; [ "$OS" = rhel ] && SSHD_BACKEND=systemd
cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
ignoreip = 127.0.0.1/8 ::1 ${ADMIN_IPS}

[sshd]
enabled = true
port    = ${SSH_PORT}
backend = ${SSHD_BACKEND}

[nginx-limit-req]
enabled  = true
port     = http,https
logpath  = /var/log/nginx/error.log
maxretry = 20

[nginx-botsearch]
enabled = true
port    = http,https
logpath = /var/log/nginx/access.log
EOF
systemctl enable --now fail2ban
systemctl restart fail2ban

# -----------------------------------------------------------------------------
log "11. SSH 하드닝 (마지막 단계, Spec 7.1)"
# -----------------------------------------------------------------------------
ALLOW_USERS="deploy"
for ip in $ADMIN_IPS; do ALLOW_USERS="$ALLOW_USERS ${ADMIN_USER}@${ip}"; done
cat > /etc/ssh/sshd_config.d/00-hardening.conf <<EOF
# bootstrap.sh 생성. sshd 는 먼저 읽은 값이 우선이므로 00- 접두사로 둔다.
Port ${SSH_PORT}
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
PermitEmptyPasswords no
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no
MaxAuthTries 3
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
# 관리자는 고정 IP 에서만, deploy 는 강제명령 키로만
AllowUsers ${ALLOW_USERS}

# 관리자는 DB 접속용 SSH 터널(127.0.0.1:3306)만 허용 (Spec 7.2)
Match User ${ADMIN_USER}
    AllowTcpForwarding local
    PermitOpen 127.0.0.1:3306
EOF
install -d -m 0755 /run/sshd
sshd -t || die "sshd 설정 검증 실패 — 00-hardening.conf 확인"
systemctl restart sshd 2>/dev/null || systemctl restart ssh

log "완료"
cat <<EOF

다음을 확인하세요.
  1) 기존 세션을 유지한 채 새 터미널에서:  ssh -p ${SSH_PORT} ${ADMIN_USER}@<서버IP>
  2) cafe24 콘솔 방화벽에도 동일 정책 적용: 80/443 전체, ${SSH_PORT}/tcp $( [ "$DEPLOY_FROM_GITHUB" = 1 ] && echo "전체(sshd 에서 계정·IP 제한)" || echo "${ADMIN_IPS}" )
  3) GitHub 저장소 시크릿 등록: DEPLOY_HOST, DEPLOY_PORT=${SSH_PORT}, DEPLOY_SSH_KEY, DEPLOY_KNOWN_HOSTS
       DEPLOY_KNOWN_HOSTS 값:  ssh-keyscan -p ${SSH_PORT} <서버IP>  (출력의 지문을 서버에서 직접 대조)
  4) main 브랜치에 push → CI 통과 → production 승인 → 첫 배포
  5) https://${DOMAIN}/health 가 {"status":"UP"} 이면 M0 완료 기준 충족
EOF
