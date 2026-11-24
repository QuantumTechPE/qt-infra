# Levantamiento total en el servidor definitivo

Guía para llevar la plataforma del servidor de pruebas al servidor definitivo, o para instalarla desde cero.

## Qué se mueve y qué no

| Componente | ¿Se mueve? | Notas |
|---|---|---|
| GitHub: repos, tablero, GitHub App, rulesets, variables de organización | **No** | Queda igual. Los micros siguen llamando a `qt-infra@master` |
| Imágenes (GHCR) y releases | **No** | Viven en GitHub |
| **Plataforma**: Vault, SonarQube, runners, toolbox | **Sí** | Al servidor de plataforma (Linux con Docker) |
| **Clústeres** dev, qa y prod | **Sí** | De k3d (pruebas) a k3s en servidores reales |
| Despliegues de los micros | Se recrean solos | Argo CD los toma de `qt-gitops` |

Hay dos caminos:

- **A. Migrar desde el servidor de pruebas (recomendado).** Conserva los secretos de los micros, la llave de la GitHub App, el contador de códigos `QT-<n>`, la agenda de pases y la CA (las variables de GitHub no cambian).
- **B. Instalar desde cero.** Hay que volver a cargar todo eso a mano (ver [Camino B](#camino-b-instalación-desde-cero)).

## Parámetros que cambian

| Parámetro | Archivo | Valor en el servidor definitivo |
|---|---|---|
| `PLATFORM_HOST` | `platform/.env` | IP o **DNS** del servidor de plataforma. Va en el certificado de Vault y es la URL de Vault que usan los clústeres. Con un nombre DNS (p. ej. `vault.quantumtech.local`), una futura mudanza solo cambia el DNS |
| `INGRESS_DOMAIN_DEV/QA/PROD` | `platform/.env` | **Vacíos** (se usa `<IP del primer control-plane>.nip.io`) o tu dominio |
| `INGRESS_PORT_DEV/QA/PROD` | `platform/.env` | **Vacíos** (puerto 80). Solo se usaban con los clústeres locales k3d |
| `RUNNER_REPLICAS` | `platform/.env` | Runners en paralelo según la capacidad del servidor (2 a 4) |
| IPs de los nodos | `k8s/provisioning/inventories/{dev,qa,prod}/hosts.yml` | Tus servidores k3s |
| `ingress_domain` (opcional) | Los mismos inventarios | Tu dominio, si no usas nip.io |
| `PASE_TZ` (opcional) | Variable de la organización en GitHub | Zona horaria de los pases (por defecto `America/Lima`) |

No cambian: `GITHUB_OWNER`, `GITHUB_APP_LOGIN`, `GOVERNANCE_APP_ID`, `ADMIN_APPROVALS_REQUIRED`, `VAULT_AUDIENCE`, `INFRA_REPO` ni `GITOPS_REPO`.

## 0. Requisitos

| Máquina | Requisitos |
|---|---|
| **Servidor de plataforma** | Linux (Ubuntu 22.04/24.04 o similar), Docker Engine con el plugin compose, git y curl. Recomendado: 4 vCPU, 8 GB de RAM, 60 GB de disco. SonarQube usa unos 3 GB de RAM |
| **Servidores k3s** (por ambiente) | Linux con systemd y un usuario con `sudo` sin contraseña. Mínimo 1 nodo por ambiente; prod, recomendado 3 control-plane. Disco para métricas y logs: dev 20 GB, qa 40 GB y prod 100 GB |

**Red:**

| Desde | Hacia | Puerto | Para |
|---|---|---|---|
| Nodos de los clústeres | Servidor de plataforma | 8200/tcp | External Secrets → Vault |
| Servidor de plataforma | Control-plane de cada clúster | 6443/tcp | Vault (TokenReview) y toolbox (kubectl/helm) |
| Servidor de plataforma | Nodos de cada clúster | 22/tcp, 80/tcp | Ansible (SSH) y runners → Argo CD (Ingress) |
| Nodos entre sí | — | 6443, 10250/tcp, 8472/udp (+2379-2380 en HA) | k3s |
| Usuarios | Nodos de cada clúster | 80/tcp | Aplicaciones, Grafana y Argo CD |
| Todo | Internet | 443 | GitHub, GHCR, charts, Sigstore |

## 1. Respaldo en el servidor de pruebas (camino A)

En la PC de pruebas (PowerShell):

```powershell
cd E:\QT\Infra\platform
.\qt.ps1 down        # detiene todo: los runners dejan de tomar jobs

New-Item -ItemType Directory -Force E:\QT\qt-backup | Out-Null
foreach ($v in 'vault-data', 'sonar-db', 'sonar-data') {
    docker run --rm -v "qt-platform_${v}:/data" -v "E:\QT\qt-backup:/backup" alpine:3.24 `
        tar czf "/backup/${v}.tgz" -C /data .
}
tar czf E:\QT\qt-backup\platform-local.tgz .env .secrets
```

> ⚠️ `platform-local.tgz` contiene las **llaves de desbloqueo y el root token de Vault** y la llave privada de la CA. Cópialo solo por un canal cifrado y bórralo cuando termines.

Copia la carpeta al servidor definitivo:

```powershell
scp E:\QT\qt-backup\* usuario@servidor:~/qt-backup/
```

## 2. Plataforma en el servidor definitivo

```bash
git clone https://github.com/QuantumTechPE/qt-infra.git ~/qt-infra
cd ~/qt-infra/platform

# Camino A: restaurar configuración, secretos y datos
tar xzf ~/qt-backup/platform-local.tgz            # .env y .secrets/
rm -f .secrets/kubeconfig-*                       # eran de los clústeres de prueba
for v in vault-data sonar-db sonar-data; do
  docker volume create --label com.docker.compose.project=qt-platform \
    --label com.docker.compose.volume="$v" "qt-platform_${v}"
  docker run --rm -v "qt-platform_${v}:/data" -v ~/qt-backup:/backup alpine:3.24 \
    tar xzf "/backup/${v}.tgz" -C /data
done
```

Edita `platform/.env` con los [parámetros que cambian](#parámetros-que-cambian):

```ini
PLATFORM_HOST=vault.quantumtech.local     # IP o DNS de ESTE servidor
INGRESS_DOMAIN_DEV=
INGRESS_DOMAIN_QA=
INGRESS_DOMAIN_PROD=
INGRESS_PORT_DEV=
INGRESS_PORT_QA=
INGRESS_PORT_PROD=
RUNNER_REPLICAS=2
```

Levanta la plataforma:

```bash
./qt.sh up
```

`up` es idempotente:
- Conserva la CA y re-emite el certificado de Vault con el nuevo `PLATFORM_HOST`.
- Vault arranca con los datos restaurados y se desbloquea solo.
- Actualiza roles y políticas.
- Los runners se registran en la organización con la GitHub App.

Verifica:

```bash
./qt.sh status            # Vault: "sealed": false
./qt.sh logs runner       # "Listening for Jobs" (Ctrl+C para salir)
```

En GitHub: *Organization settings → Actions → Runners* muestra los runners nuevos en línea. Los de la PC de pruebas desaparecen solos, porque son efímeros.

## 3. Clústeres k3s

1. Edita los inventarios con las IPs de tus servidores: `k8s/provisioning/inventories/{dev,qa,prod}/hosts.yml`.

   ```yaml
   all:
     vars:
       cluster_env: prod
       ansible_user: ubuntu
       # ingress_domain: quantumtech.com
     children:
       k3s_server:
         hosts:
           prod-cp-1:
             ansible_host: 192.168.30.11
       k3s_agent:
         hosts:
           prod-w-1:
             ansible_host: 192.168.30.21
   ```

2. Llave SSH de la plataforma. Muestra la llave pública; agrégala en `~/.ssh/authorized_keys` del usuario de cada nodo:

   ```bash
   ./qt.sh ssh-key
   ```

3. Instala k3s (Ansible, con el binario verificado por SHA-256) y conecta cada clúster con Vault y Argo CD:

   ```bash
   ./qt.sh k8s-provision dev && ./qt.sh k8s-bootstrap dev
   ./qt.sh k8s-provision qa  && ./qt.sh k8s-bootstrap qa
   ./qt.sh k8s-provision prod && ./qt.sh k8s-bootstrap prod
   ```

   `k8s-bootstrap` imprime las URLs de Argo CD y Grafana de cada ambiente.

## 4. Apuntar `qt-gitops` al servidor definitivo

Los clústeres leen la URL de Vault y el dominio desde `qt-gitops/clusters/<ambiente>/`. Regenéralos y súbelos por PR:

```bash
./qt.sh gitops-render                              # → platform/.generated/qt-gitops
git clone https://github.com/QuantumTechPE/qt-gitops.git /tmp/qt-gitops
cp -r .generated/qt-gitops/clusters/. /tmp/qt-gitops/clusters/
cd /tmp/qt-gitops
git switch -c chore/servidor-definitivo
git diff --stat      # solo deben cambiar la URL de Vault y los dominios
git commit -am "chore: clústeres en el servidor definitivo"
git push -u origin chore/servidor-definitivo
```

Abre el PR a `master`. Debe aprobarlo **un admin distinto del autor**, porque GitHub no permite autoaprobarse; también puede abrirlo la plataforma con su GitHub App. Al mergearse, Argo CD de cada clúster despliega los add-ons y los microservicios. External Secrets toma los secretos del Vault nuevo.

> Revisa el diff antes del commit: si alguien cambió add-ons directamente en `qt-gitops`, el render los sobrescribe. Deja solo las líneas de Vault y de dominio.

## 5. GitHub (normalmente no hace falta)

Con el camino A la CA es la misma, así que las variables de la organización (`VAULT_CA_B64`…) no cambian. Solo si la CA cambió (camino B):

```bash
gh auth login -s admin:org,project,workflow
cd ~/qt-infra && bash platform/scripts/github-bootstrap.sh     # idempotente
```

## 6. Verificación final

```bash
cd ~/qt-infra/platform
for e in dev qa prod; do
  docker compose run --rm -T toolbox bash -c \
    "KUBECONFIG=/secrets/kubeconfig-$e kubectl -n argocd get applications"
done
```

- Todas las aplicaciones deben quedar **Synced / Healthy**.
- En *qt-infra → Actions*, el **Agendador de pases** corre cada 5 minutos en verde.
- **Prueba de punta a punta:** un push a la rama `qt/<n>` de una historia debe desplegar en DEV.
- **Credenciales:**

  | Qué | Dónde |
  |---|---|
  | Grafana | Vault `secret/platform/observability/<ambiente>` |
  | Argo CD | Vault `secret/platform/argocd-admin/<ambiente>` |
  | SonarQube | Vault `secret/platform/sonarqube-admin` |

  El token de Vault se obtiene con `./qt.sh vault-token`.

## 7. Apagar el servidor de pruebas

Cuando todo esté verificado, en la PC de pruebas:

```powershell
cd E:\QT\Infra\platform
.\qt.ps1 down                                        # si no se hizo en el paso 1
.\.bin\k3d.exe cluster delete qt-dev qt-qa qt-prod   # clústeres de prueba
```

Así no quedan runners ni Argo CD duplicados. `.\qt.ps1 destroy` borra además los datos locales de la PC: es **irreversible**, úsalo solo cuando el servidor definitivo esté operando. Borra también `E:\QT\qt-backup` y la copia en `~/qt-backup` del servidor.

## Camino B: instalación desde cero

Si no hay respaldo, o se quiere empezar limpio:

1. **Plataforma:**

   ```bash
   git clone https://github.com/QuantumTechPE/qt-infra.git ~/qt-infra && cd ~/qt-infra/platform
   ./qt.sh up      # la primera vez crea .env y se detiene: edítalo y vuelve a ejecutar
   ./qt.sh up
   ```

2. **GitHub App:** genera una private key nueva en *Organization settings → Developer settings → GitHub Apps → quantumtechpe-platform → Private keys*. Luego:

   ```bash
   ./qt.sh github-app 5894640 Iv23liEqsLc1IgT74gZb ~/quantumtechpe-platform.pem
   ```

3. **GitHub:** sigue el [paso 5](#5-github-normalmente-no-hace-falta). Es obligatorio aquí, porque la CA es nueva.

4. **Contador de códigos `QT-<n>`.** Ponlo en el último código usado; si no, se repetirían:

   ```bash
   docker compose run --rm -T toolbox bash -c \
     'source /scripts/lib.sh; vault_root_login; vault kv put secret/platform/story-seq last=<ÚLTIMO_N>'
   ```

5. **Secretos de cada microservicio** por ambiente:

   ```bash
   ./qt.sh secret-list     <servicio> <dev|qa|prod>
   ./qt.sh secret-set      <servicio> <dev|qa|prod> <CLAVE>    # pide el valor sin mostrarlo
   ./qt.sh secret-generate <servicio> <dev|qa|prod> <CLAVE>    # valor aleatorio
   ```

6. **SonarQube** (si no se restauró su volumen): regenera el token de análisis para el CI:

   ```bash
   docker compose run --rm -T -e ROTATE=true toolbox bash /scripts/sonar-bootstrap.sh
   ```

7. **Pases pendientes:** la agenda se pierde; vuelve a comentar `/agendar` en los issues de pase abiertos.

8. Continúa con los pasos [3](#3-clústeres-k3s), [4](#4-apuntar-qt-gitops-al-servidor-definitivo) y [6](#6-verificación-final).
