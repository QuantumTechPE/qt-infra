package com.qt.api;

import static io.restassured.RestAssured.given;
import static org.hamcrest.Matchers.equalTo;
import static org.hamcrest.Matchers.notNullValue;

import io.quarkus.test.junit.QuarkusTest;
import org.junit.jupiter.api.Test;

@QuarkusTest
class InfoResourceTest {

    @Test
    void returnsApplicationIdentity() {
        given()
                .when().get("/info")
                .then()
                .statusCode(200)
                .body("name", equalTo("qt-template-quarkus"))
                .body("environment", equalTo("test"))
                .body("version", notNullValue());
    }

    @Test
    void livenessProbeIsUpOutsideApiPrefix() {
        // Health vive en /q (fuera de /api): es lo que consultan los probes de Kubernetes.
        given()
                .basePath("")
                .when().get("/q/health/live")
                .then()
                .statusCode(200)
                .body("status", equalTo("UP"));
    }

    @Test
    void readinessProbeIsUpOutsideApiPrefix() {
        given()
                .basePath("")
                .when().get("/q/health/ready")
                .then()
                .statusCode(200)
                .body("status", equalTo("UP"));
    }

    @Test
    void metricsAreExposedForPrometheus() {
        given()
                .basePath("")
                .when().get("/q/metrics")
                .then()
                .statusCode(200);
    }
}
