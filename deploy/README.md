# 서버 구축·배포 런북 (M0)

대상: cafe24 가상서버호스팅, Rocky Linux 9 또는 Ubuntu 22.04 LTS, 단일 서버(웹+앱+DB).

## 파일

| 파일 | 서버 위치 | 용도 |
| --- | --- | --- |
| `server/bootstrap.sh` | (1회 실행) | 하드닝·패키지·DB 계정·Nginx·TLS·방화벽·fail2ban·SSH |
| `nginx/nginx.conf` | `/etc/nginx/nginx.conf` | 전역 설정, 요청 제한 zone |
| `nginx/app-http.conf` | `/etc/nginx/conf.d/` | 80: ACME + HTTPS 리다이렉트 |
| `nginx/app-https.conf` | `/etc/nginx/conf.d/` | 443: 서비스 도메인, ops 도메인(IP 허용목록) |
| `nginx/snippets/*.conf` | `/etc/nginx/snippets/` | TLS(Mozilla Intermediate)+HSTS, 프록시 헤더 |
| `systemd/app.service` | `/etc/systemd/system/` | `app` 계정, 샌드박스 옵션 |
| `bin/app-deploy-gate` | `/usr/local/bin/` | deploy 키의 강제 명령 (명령 화이트리스트) |
| `bin/app-deploy` | `/usr/local/sbin/` | 체크섬 검증 → Flyway → 재시작 → 헬스체크 → 자동 롤백 |
| `bin/cert-expiry-check` | `/usr/local/sbin/` | 인증서 만료 14일 전 경고 (cron) |
| `secrets.env.example` | `/etc/app/secrets.env` | 형식 예시 (실제 값은 bootstrap 이 무작위 생성) |

서버 디렉터리: `/opt/app/releases/*.jar`, `/opt/app/current.jar`·`previous.jar`(심볼릭 링크),
`/var/lib/app/uploads`(웹루트 밖), `/var/log/app`, `/etc/app/secrets.env`(root:app 640).

## 1. 사전 준비

1. cafe24 가상서버 생성, 관리자 계정(`admin` 등)에 SSH 공개키 등록
2. DNS: `DOMAIN`, `ops.DOMAIN` A 레코드 → 서버 IP
3. 배포 전용 키 생성 (로컬에서):
   ```bash
   ssh-keygen -t ed25519 -N "" -C github-actions-deploy -f deploy_key
   ```
4. cafe24 콘솔 방화벽: 80/443 전체 허용, 새 SSH 포트 허용 (아래 "SSH 노출 범위" 참고)

## 2. 부트스트랩

```bash
scp -r deploy admin@<서버IP>:~/
ssh admin@<서버IP>
sudo DOMAIN=quote.example.co.kr ADMIN_USER=admin ADMIN_IPS="203.0.113.10" \
     SSH_PORT=22022 CERT_EMAIL=ops@example.co.kr \
     DEPLOY_PUBKEY="ssh-ed25519 AAAA... github-actions-deploy" \
     bash ~/deploy/server/bootstrap.sh
```

`DEPLOY_PUBKEY` 에는 로컬에서 만든 `deploy_key.pub` 내용을 그대로 넣습니다.

- DNS 전파 전이면 `SKIP_TLS=1` 로 먼저 실행하고, 전파 후 다시 실행합니다 (재실행 안전).
- **기존 SSH 세션을 닫지 말고** 새 터미널에서 `ssh -p 22022 admin@<서버IP>` 접속을 확인하세요.

## 3. GitHub 설정

| 위치 | 항목 |
| --- | --- |
| Settings → Secrets → Actions | `NVD_API_KEY` (https://nvd.nist.gov/developers/request-an-api-key) |
| Settings → Environments → `production` | Required reviewers 지정, secrets: `DEPLOY_HOST`, `DEPLOY_PORT`, `DEPLOY_SSH_KEY`(deploy_key 개인키), `DEPLOY_KNOWN_HOSTS`(`ssh-keyscan -p <포트> <IP>` 결과, 지문을 서버에서 대조) |
| Settings → Branches | `main`: PR 필수, 리뷰 1인, status check `빌드·테스트·정적분석`, `의존성 취약점`, `비밀값 스캔` 필수 |
| Settings → Code security | Dependabot alerts / security updates 활성화 |

개인키 파일(`deploy_key`)은 시크릿 등록 후 로컬에서 삭제합니다.

## 4. 배포·롤백

- 자동: `main` push → CI → `production` 승인 → `ssh deploy@host "deploy <sha256> <rev>" < app.jar`
- 수동 (운영자 PC, deploy 키 보유 시):
  ```bash
  ssh -p 22022 deploy@<서버IP> status
  ssh -p 22022 deploy@<서버IP> rollback
  ```
- 관리자 계정으로 서버에서: `sudo app-deploy status|rollback`

| 상황 | 동작 |
| --- | --- |
| 체크섬 불일치 | 업로드 파일 삭제, 배포 중단 |
| 마이그레이션 실패 | 현재 버전 그대로 유지(재시작 없음), 업로드 JAR 삭제 |
| 재시작 후 120초 내 헬스체크 실패 | 직전 JAR 로 자동 복귀, 실패 JAR 은 `*.jar.failed` 로 보관(최근 3개) |
| 허용 외 명령 | `denied`, auth 로그 기록 |

릴리스는 최근 5개 보관합니다. **JAR 롤백은 DB 스키마를 되돌리지 않으므로** 마이그레이션은 항상 직전 버전 앱과 호환되게(추가 → 전환 → 다음 릴리스에서 삭제) 작성합니다.

## 5. SSH 노출 범위 (결정 필요)

Spec 7.1 은 "SSH 는 관리자 고정 IP 에서만" 이지만, GitHub 호스티드 러너는 IP 가 고정되지 않습니다.
`bootstrap.sh` 기본값(`DEPLOY_FROM_GITHUB=1`)은 다음과 같이 절충합니다.

- 방화벽: SSH 포트(비표준)를 전체에 개방
- sshd: `AllowUsers deploy admin@<ADMIN_IPS>` → 관리자 계정은 고정 IP 에서만, `deploy` 는 어디서나 접속 가능하지만
  키 인증만 가능하고 `command=` + `restrict` 로 `deploy/rollback/status` 외 아무것도 실행할 수 없음
- fail2ban 이 SSH 무차별 대입을 차단

네트워크 수준에서도 고정 IP 만 허용하려면 `DEPLOY_FROM_GITHUB=0` 으로 실행하고 다음 중 하나를 택합니다.

1. 서버(또는 고정 IP 사내 장비)에 GitHub self-hosted runner 를 두고 deploy 잡만 그 러너에서 실행
2. Tailscale/WireGuard 등 VPN 을 경유해 배포

## 6. Cloudflare 프록시 (미결정 사항)

사용하기로 하면: 원본 443 을 Cloudflare IP 대역(https://www.cloudflare.com/ips/)에서만 허용하도록 방화벽을 바꾸고,
Nginx 에 `set_real_ip_from <CF 대역>; real_ip_header CF-Connecting-IP;` 를 추가합니다.
이때 ops 서브도메인은 Cloudflare 를 거치지 않는 DNS-only 로 두어야 IP 허용목록이 동작합니다.

## 7. M0 완료 확인

- [ ] `https://<DOMAIN>/health` → `{"status":"UP"}`
- [ ] `https://<DOMAIN>/` 응답 헤더에 HSTS, CSP, nosniff, X-Frame-Options, Referrer-Policy, Permissions-Policy
- [ ] `http://<DOMAIN>/` → 301 https
- [ ] 허용목록 외 IP 에서 `https://ops.<DOMAIN>/` → 403
- [ ] 외부에서 8080/8081/3306 접속 불가 (`nmap -p 8080,8081,3306 <IP>`)
- [ ] 헬스체크 실패하는 JAR 배포 시 자동 롤백 (아래 "롤백 리허설")
- [ ] SSL Labs A 등급

롤백 리허설: 웹 기동 시에만 실패하는 커밋(예: `@Profile("!migrate")` 빈의 생성자에서 예외 발생)을 `main` 에 배포
(마이그레이션 단계에서 실패하는 변경은 재시작 전에 멈추므로 롤백 경로를 타지 않습니다) → 로그에
`배포 실패, 롤백 완료` 확인 → `ssh deploy@host status` 가 이전 릴리스·`UP` 인지 확인 → 해당 커밋 revert.
