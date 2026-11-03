package com.b2bmarket.quote;

import static org.assertj.core.api.Assertions.assertThat;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.client.TestRestTemplate;
import org.springframework.boot.test.web.server.LocalManagementPort;
import org.springframework.context.annotation.Import;
import org.springframework.http.HttpEntity;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.context.TestPropertySource;

/**
 * M0 완료 기준 점검: 앱 기동, Flyway V1 적용, 보안 헤더, 기본 거부 정책, 에러 정보 비노출, 헬스체크.
 */
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT)
@Import(TestcontainersConfiguration.class)
@ActiveProfiles("test")
@TestPropertySource(properties = "management.server.port=0")
class ApplicationSmokeTest {

    @Autowired
    TestRestTemplate rest;

    @Autowired
    JdbcTemplate jdbc;

    @LocalManagementPort
    int managementPort;

    @Test
    void flywayV1이_적용되어_세션_테이블이_존재한다() {
        Integer applied = jdbc.queryForObject(
                "SELECT COUNT(*) FROM flyway_schema_history WHERE version = '1' AND success = 1", Integer.class);
        assertThat(applied).isEqualTo(1);
        Integer sessions = jdbc.queryForObject("SELECT COUNT(*) FROM SPRING_SESSION", Integer.class);
        assertThat(sessions).isNotNull();
    }

    @Test
    void 홈은_공개되고_보안헤더가_붙는다() {
        ResponseEntity<String> res = rest.getForEntity("/", String.class);

        assertThat(res.getStatusCode()).isEqualTo(HttpStatus.OK);
        HttpHeaders h = res.getHeaders();
        assertThat(h.getFirst("Content-Security-Policy"))
                .contains("default-src 'self'", "script-src 'self'", "object-src 'none'", "frame-ancestors 'none'");
        assertThat(h.getFirst("X-Content-Type-Options")).isEqualTo("nosniff");
        assertThat(h.getFirst("X-Frame-Options")).isEqualTo("DENY");
        assertThat(h.getFirst("Referrer-Policy")).isEqualTo("strict-origin-when-cross-origin");
        assertThat(h.getFirst("Permissions-Policy")).contains("camera=()", "geolocation=()");
    }

    @Test
    void 공개되지_않은_경로는_인증을_요구한다() {
        ResponseEntity<String> res = rest.getForEntity("/seller/products", String.class);
        assertThat(res.getStatusCode()).isEqualTo(HttpStatus.UNAUTHORIZED);
    }

    @Test
    void CSRF_토큰_없는_POST는_거부된다() {
        ResponseEntity<String> res = rest.postForEntity("/", new HttpEntity<>("x=1"), String.class);
        assertThat(res.getStatusCode()).isEqualTo(HttpStatus.FORBIDDEN);
    }

    @Test
    void 에러_응답에_스택트레이스와_내부정보가_없다() {
        ResponseEntity<String> res = rest.getForEntity("/error", String.class);
        assertThat(res.getBody()).doesNotContain("Exception", "at com.", "trace", "Whitelabel");
    }

    @Test
    void 기본_계정이_만들어지지_않는다() {
        // Basic 인증을 켜지 않았으므로 어떤 자격증명으로도 보호 경로에 들어갈 수 없어야 한다
        ResponseEntity<String> res = rest.withBasicAuth("user", "password")
                .getForEntity("/seller/products", String.class);
        assertThat(res.getStatusCode()).isEqualTo(HttpStatus.UNAUTHORIZED);
    }

    @Test
    void 헬스체크는_관리포트에서만_응답하고_상세정보를_숨긴다() {
        ResponseEntity<String> res = rest.getForEntity(
                "http://127.0.0.1:" + managementPort + "/actuator/health", String.class);
        assertThat(res.getStatusCode()).isEqualTo(HttpStatus.OK);
        assertThat(res.getBody()).isEqualTo("{\"status\":\"UP\"}");

        ResponseEntity<String> onAppPort = rest.getForEntity("/actuator/health", String.class);
        assertThat(onAppPort.getStatusCode()).isNotEqualTo(HttpStatus.OK);
    }

    @Test
    void 다른_액추에이터_엔드포인트는_노출되지_않는다() {
        for (String ep : new String[] {"env", "beans", "configprops", "heapdump", "mappings"}) {
            ResponseEntity<String> res = rest.getForEntity(
                    "http://127.0.0.1:" + managementPort + "/actuator/" + ep, String.class);
            assertThat(res.getStatusCode()).as(ep).isIn(HttpStatus.NOT_FOUND, HttpStatus.FORBIDDEN, HttpStatus.UNAUTHORIZED);
        }
    }
}
