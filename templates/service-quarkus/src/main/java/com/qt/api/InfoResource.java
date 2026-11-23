package com.qt.api;

import jakarta.ws.rs.GET;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.core.MediaType;
import org.eclipse.microprofile.config.inject.ConfigProperty;

/**
 * Expone la identidad de la aplicación desplegada (nombre, versión y ambiente).
 * El pipeline de CD usa este endpoint como smoke test para confirmar que la
 * versión correcta quedó corriendo.
 */
@Path("/info")
@Produces(MediaType.APPLICATION_JSON)
public class InfoResource {

    private final String name;
    private final String version;
    private final String environment;

    public InfoResource(
            @ConfigProperty(name = "quarkus.application.name") String name,
            @ConfigProperty(name = "quarkus.application.version") String version,
            @ConfigProperty(name = "qt.environment", defaultValue = "local") String environment) {
        this.name = name;
        this.version = version;
        this.environment = environment;
    }

    @GET
    public AppInfo info() {
        return new AppInfo(name, version, environment);
    }

    public record AppInfo(String name, String version, String environment) {
    }
}
