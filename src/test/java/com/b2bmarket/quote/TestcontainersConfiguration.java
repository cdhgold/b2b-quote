package com.b2bmarket.quote;

import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.boot.testcontainers.service.connection.ServiceConnection;
import org.springframework.context.annotation.Bean;
import org.testcontainers.containers.MariaDBContainer;
import org.testcontainers.utility.DockerImageName;

/** 운영과 같은 MariaDB 10.11 로 통합 테스트를 수행한다. */
@TestConfiguration(proxyBeanMethods = false)
public class TestcontainersConfiguration {

    @Bean
    @ServiceConnection
    MariaDBContainer<?> mariaDbContainer() {
        return new MariaDBContainer<>(DockerImageName.parse("mariadb:10.11"))
                .withCommand("--character-set-server=utf8mb4", "--collation-server=utf8mb4_unicode_ci");
    }
}
