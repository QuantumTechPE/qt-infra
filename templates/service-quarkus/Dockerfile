####
# Imagen de runtime (Quarkus fast-jar sobre JVM 21, usuario no root 185).
#
# El pipeline NO compila dentro de Docker: descarga el artefacto `quarkus-app`
# del job de build, verifica su SHA-256 y recién entonces lo empaqueta aquí
# ("build once, deploy many": la misma imagen recorre dev → qa → prod).
#
# Build local:
#   ./mvnw package && docker build -t qt-template-quarkus .
####
FROM registry.access.redhat.com/ubi9/openjdk-21-runtime:1.24

# Parches del SO publicados después de la imagen base: el quality gate de Trivy
# bloquea HIGH/CRITICAL que ya tienen corrección.
USER root
RUN microdnf update -y --nodocs --setopt=install_weak_deps=0 && microdnf clean all

ENV LANGUAGE='en_US:en'

COPY --chown=185 target/quarkus-app/lib/ /deployments/lib/
COPY --chown=185 target/quarkus-app/*.jar /deployments/
COPY --chown=185 target/quarkus-app/app/ /deployments/app/
COPY --chown=185 target/quarkus-app/quarkus/ /deployments/quarkus/

# Quarkus lee ./config/application.properties (ConfigMap del ambiente montado en
# /deployments/config) con prioridad sobre el application.properties empaquetado.
WORKDIR /deployments

EXPOSE 8080
USER 185
ENV JAVA_OPTS_APPEND="-Dquarkus.http.host=0.0.0.0 -Djava.util.logging.manager=org.jboss.logmanager.LogManager"
ENV JAVA_APP_JAR="/deployments/quarkus-run.jar"

ENTRYPOINT [ "/opt/jboss/container/java/run/run-java.sh" ]
