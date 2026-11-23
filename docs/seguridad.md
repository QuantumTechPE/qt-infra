# Modelo de seguridad

## Cero secretos en GitHub

Ni la organización ni los repos guardan secretos. Los jobs obtienen credenciales de **Vault (TLS)** con el token **OIDC** del propio job:

| Rol de Vault | Quién lo puede usar | Accede a |
|---|---|---|
| `gha-ci` | Cualquier repo de la organización | `secret/ci/*` (token de análisis de Sonar, API key de Dependency-Track) |
| `gha-automation` | Solo `qt-infra/service-governance`, `service-project` y `service-cd` **@master**, ejecutados desde `master` | Credencial de la GitHub App |
| `gha-promote-<env>` | Solo `qt-infra/_promote.yml`, desde `master`, con el **environment** `<env>` (prod exige aprobación de admins) | GitHub App + token de Argo CD del ambiente |
| `gha-provision` | Solo `qt-infra/new-service.yml` desde `master`, con el environment `provisioning` (aprobación de admins) | GitHub App + **crear** (no leer ni sobrescribir) `secret/apps/*` |
| AppRole `github-runner` | Contenedores runner | GitHub App (para registrarse) |
| Auth Kubernetes `k8s-<env>` | ServiceAccount de External Secrets del clúster `<env>` (audiencia `vault`) | `secret/apps/*/<env>` y la credencial de Grafana de `<env>` |

Un PR malicioso puede modificar workflows, pero su token OIDC dirá `ref: refs/pull/N/merge`: no obtendrá la App ni podrá promover. Un clúster tampoco puede leer secretos de otro ambiente. La auditoría de Vault registra cada acceso.

## Gobierno

- `master` sin bypass en todos los repos: PR, aprobación de un admin, code owners y checks requeridos.
- `governance/admin-approvals` lo emite la GitHub App, desde código de `master` (`workflow_run`).
- En `qt-gitops` solo la App escribe directo (las promociones). La de prod ocurre únicamente tras la aprobación del environment.
- Tags `v*` inmutables. Allowlist de actions a nivel organización.

## Supply chain

| Etapa | Control |
|---|---|
| Dependencias | Maven `--strict-checksums`; `npm ci` (sha512) y `npm audit signatures` |
| Herramientas | Versiones fijas verificadas por SHA-256 (gitleaks, helm, kubeconform, kubectl, k3s, actionlint) |
| Entre jobs | Cada artefacto viaja con su `.sha256` y se verifica antes de empaquetarlo |
| Imagen | Trivy **antes** de firmar; firma keyless **cosign**; attestations **SLSA** y **SBOM** |
| Promoción | `cosign verify` + `gh attestation verify --signer-workflow qt-infra/_image.yml --source-ref refs/heads/master` |
| Admisión en el clúster | **Kyverno** `ImageValidatingPolicy`: solo imágenes firmadas por `qt-infra/_image.yml` |
| Release | `SHA256SUMS` firmado + attestation de binarios |

## Endurecimiento de los clústeres

- **Pod Security "restricted"** en los namespaces de microservicios.
- Contenedores sin root, filesystem **de solo lectura**, `drop: [ALL]`, seccomp y sin token de ServiceAccount.
- **NetworkPolicy**: cada servicio solo acepta tráfico de su namespace y del Ingress.
- `AppProject services`: los micros solo pueden desplegar el chart de `qt-infra` con valores de `qt-gitops` y no crean recursos de clúster.
- Health y métricas (`/q/*`) no se exponen por el Ingress.
- Secretos de Kubernetes cifrados en etcd (`secrets-encryption`).

## Límites conocidos

| Límite | Recomendación para producción real |
|---|---|
| Vault de un nodo con la unseal key en disco (`platform/.secrets`) | Vault en HA (3 nodos), auto-unseal con KMS o Transit, revocar el root token y usar OIDC para personas |
| Argo CD expuesto por HTTP en la red interna | cert-manager + TLS en el Ingress |
| Runners con socket de Docker de la máquina de plataforma | Actions Runner Controller dentro de Kubernetes |
| Los secretos rotados en Vault no reinician los pods | Agregar Stakater Reloader o rotar con rollout |
| Kyverno y Argo CD descargan de internet (Sigstore, charts, GHCR) | Mirror interno de imágenes y charts si la red es aislada |
