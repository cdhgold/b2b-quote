package com.b2bmarket.quote.global.security;

import org.springframework.boot.actuate.autoconfigure.security.servlet.EndpointRequest;
import org.springframework.boot.actuate.health.HealthEndpoint;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.http.HttpStatus;
import org.springframework.security.config.annotation.method.configuration.EnableMethodSecurity;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.config.annotation.web.configuration.EnableWebSecurity;
import org.springframework.security.web.SecurityFilterChain;
import org.springframework.security.web.authentication.HttpStatusEntryPoint;
import org.springframework.security.web.header.writers.ReferrerPolicyHeaderWriter.ReferrerPolicy;
import org.springframework.security.web.header.writers.StaticHeadersWriter;

/**
 * 웹 보안 기본 설정 (Spec 6.2, 6.3, 6.5).
 *
 * <ul>
 *   <li>CSRF: Spring Security 기본값 유지 (끄지 않음)</li>
 *   <li>보안 헤더: CSP / nosniff / frame deny / Referrer-Policy / Permissions-Policy 는 앱에서,
 *       HSTS 는 TLS 를 종단하는 Nginx 에서 붙인다 (중복 헤더 방지)</li>
 *   <li>기본 정책은 deny: 공개 경로만 명시적으로 열고 나머지는 인증 필요</li>
 * </ul>
 */
@Configuration
@EnableWebSecurity
@EnableMethodSecurity
public class SecurityConfig {

    static final String CONTENT_SECURITY_POLICY =
            "default-src 'self'; script-src 'self'; object-src 'none'; frame-ancestors 'none'; "
                    + "base-uri 'self'; form-action 'self'";

    static final String PERMISSIONS_POLICY = "camera=(), microphone=(), geolocation=(), payment=(), usb=()";

    @Bean
    SecurityFilterChain securityFilterChain(HttpSecurity http) throws Exception {
        http
                .authorizeHttpRequests(auth -> auth
                        .requestMatchers(EndpointRequest.to(HealthEndpoint.class)).permitAll()
                        .requestMatchers(EndpointRequest.toAnyEndpoint()).denyAll()
                        .requestMatchers("/", "/error", "/favicon.ico", "/css/**", "/js/**", "/images/**").permitAll()
                        .anyRequest().authenticated())
                // M1 에서 로그인 페이지로 교체. 그 전까지 보호 경로는 401 로 응답한다.
                .exceptionHandling(ex -> ex.authenticationEntryPoint(new HttpStatusEntryPoint(HttpStatus.UNAUTHORIZED)))
                .headers(headers -> headers
                        .contentSecurityPolicy(csp -> csp.policyDirectives(CONTENT_SECURITY_POLICY))
                        .frameOptions(frame -> frame.deny())
                        .referrerPolicy(ref -> ref.policy(ReferrerPolicy.STRICT_ORIGIN_WHEN_CROSS_ORIGIN))
                        .httpStrictTransportSecurity(hsts -> hsts.disable())
                        .addHeaderWriter(new StaticHeadersWriter("Permissions-Policy", PERMISSIONS_POLICY)));
        return http.build();
    }
}
