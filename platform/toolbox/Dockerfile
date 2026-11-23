# Contenedor de utilidades de la plataforma: bootstrap de Vault/SonarQube/
# Dependency-Track, aprovisionamiento de k3s (Ansible) y bootstrap de clústeres
# (kubectl + Helm). En el host solo se necesita Docker.
FROM hashicorp/vault:2.2.2 AS vault

FROM alpine:3.24

ARG TARGETARCH=amd64
ARG KUBECTL_VERSION=v1.37.2
ARG HELM_VERSION=v4.3.2

RUN apk add --no-cache bash curl jq openssl ca-certificates git openssh-client ansible-core yq-go

# kubectl y helm con versión fija y SHA-256 verificado contra lo publicado
RUN set -eux; \
    cd /tmp; \
    curl -fsSLo kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl"; \
    echo "$(curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl.sha256")  kubectl" | sha256sum -c -; \
    install -m 0755 kubectl /usr/local/bin/kubectl; \
    curl -fsSLo helm.tgz "https://get.helm.sh/helm-${HELM_VERSION}-linux-${TARGETARCH}.tar.gz"; \
    echo "$(curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-${TARGETARCH}.tar.gz.sha256sum" | cut -d' ' -f1)  helm.tgz" | sha256sum -c -; \
    tar -xzf helm.tgz "linux-${TARGETARCH}/helm"; \
    install -m 0755 "linux-${TARGETARCH}/helm" /usr/local/bin/helm; \
    rm -rf /tmp/*

COPY --from=vault /bin/vault /usr/local/bin/vault

RUN adduser -D -u 1000 qt
USER 1000
WORKDIR /home/qt
ENV HELM_CACHE_HOME=/tmp/helm/cache \
    HELM_CONFIG_HOME=/tmp/helm/config \
    HELM_DATA_HOME=/tmp/helm/data \
    ANSIBLE_LOCAL_TEMP=/tmp/ansible \
    ANSIBLE_REMOTE_TEMP=/tmp/.ansible
