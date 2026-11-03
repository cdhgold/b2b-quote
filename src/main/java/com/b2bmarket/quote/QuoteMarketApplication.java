package com.b2bmarket.quote;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.boot.autoconfigure.security.servlet.UserDetailsServiceAutoConfiguration;

/**
 * 계측기·전자부품 B2B 견적 마켓플레이스.
 *
 * <p>{@link UserDetailsServiceAutoConfiguration}을 제외해 Spring Boot의 기본 계정(user / 생성 비밀번호)이
 * 만들어지지 않게 한다 (Spec 6.3 A05 "기본 계정 없음"). 실제 사용자 인증은 M1의 auth 모듈에서 구현한다.
 */
@SpringBootApplication(exclude = UserDetailsServiceAutoConfiguration.class)
public class QuoteMarketApplication {

    public static void main(String[] args) {
        SpringApplication.run(QuoteMarketApplication.class, args);
    }
}
