# B2B 견적 마켓플레이스

계측기·전자부품 판매사용 견적·가격관리 SaaS + 바이어용 통합 카탈로그.
설계 기준: [docs/개발스펙.md](docs/개발스펙.md)

현재 단계: **M0 기반** (프로젝트 골격, Flyway V1, CI, 배포·서버 하드닝 스크립트)

## 기술 스택

Java 17 (Temurin) · Spring Boot 3.5 · Spring Security 6 · Thymeleaf · MyBatis 3 · MariaDB 10.11 · Flyway · Spring Session JDBC · Nginx · GitHub Actions

## 로컬 개발

```bash
docker compose up -d            # MariaDB 10.11 (127.0.0.1:3306)
./gradlew bootRun               # 기본 프로파일 local → http://localhost:8080
./gradlew build                 # 컴파일 + 테스트(Testcontainers, Docker 필요) + SpotBugs + 보안 린트
./gradlew dependencyCheckAnalyze   # OWASP Dependency-Check (NVD_API_KEY 환경변수 권장)
```

비밀값 커밋 방지 훅 (gitleaks 설치 필요):

```bash
git config core.hooksPath .githooks
```

## 구조

```
src/main/java/com/b2bmarket/quote/
  global/        security 설정, 공통 컨트롤러 (TenantContext·에러·감사는 M1)
  auth/ org/ catalog/ pricing/ quote/ subscription/ file/ audit/ ops/   도메인 모듈 (package-info 에 책임 명시)
src/main/resources/
  application.yml / -local / -prod / -migrate   (비밀값 없음)
  db/migration/   Flyway (V1__init.sql: Spring Session 테이블)
  mapper/         MyBatis XML
deploy/          nginx, systemd, 배포·롤백 스크립트, 서버 부트스트랩 → deploy/README.md
.github/         CI(ci.yml), Dependabot
config/          SpotBugs 제외 규칙, Dependency-Check 억제 목록
```

## 보안 기본값 (M0 에서 적용됨)

| 항목 | 위치 |
| --- | --- |
| CSP·nosniff·frame deny·Referrer·Permissions-Policy | `SecurityConfig` (앱) |
| HSTS, TLS 1.2/1.3, `server_tokens off`, 요청 제한 | `deploy/nginx` |
| CSRF 기본 활성, 기본 계정 없음, 미지정 경로 인증 필요 | `SecurityConfig`, `QuoteMarketApplication` |
| 에러 응답에 스택·메시지 비노출 | `application.yml` `server.error.*` |
| Actuator 는 127.0.0.1:8081, health 만 노출 | `application.yml` `management.*` |
| MyBatis `${}`·Thymeleaf `th:utext` 차단 | `./gradlew securityLint` (`check` 에 포함) |
| 앱 DB 계정 DML 전용, 마이그레이션은 별도 계정 | `application-migrate.yml`, `deploy/server/bootstrap.sh` |

`${}` 가 꼭 필요한 경우(화이트리스트 정렬 컬럼)에만 바로 윗줄에 `<!-- SAFE-DOLLAR: 사유 -->` 를 달아 예외 처리합니다.

## 브랜치·배포

- `main`(운영) / `develop` / `feature/*`. `main` 머지는 PR 리뷰 1인 + CI 통과 필수 (GitHub 브랜치 보호 규칙으로 설정).
- `main` push → CI(빌드·테스트·SpotBugs·Dependency-Check·gitleaks) → `production` 환경 승인 → 서버 배포.
- 서버는 체크섬 재검증 → Flyway → 재시작 → 헬스체크, 실패 시 직전 JAR 로 자동 롤백.
- 마이그레이션은 **이전 버전 앱과 호환되게** 작성합니다 (JAR 롤백은 스키마를 되돌리지 않음).
