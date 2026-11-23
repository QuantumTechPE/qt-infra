#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# PKI interna de la plataforma (idempotente):
#   - CA propia (10 años)          → platform/.secrets/tls/ca.crt (+ ca.b64 para GitHub/ESO)
#   - certificado de Vault (825 d) → vault.crt / vault.key, con SAN para la red Docker,
#     localhost y PLATFORM_HOST (IP/DNS por los que llegan los clústeres k3s)
# Se re-emite el certificado si cambian los SAN o vence en menos de 30 días.
# -----------------------------------------------------------------------------
source /scripts/lib.sh

: "${PLATFORM_HOST:?Define PLATFORM_HOST en platform/.env}"
mkdir -p "$TLS_DIR"
chmod 700 "$TLS_DIR" 2>/dev/null || true
cd "$TLS_DIR" || exit 1

if [[ ! -s ca.key || ! -s ca.crt ]]; then
  info "Creando CA interna de la plataforma"
  (umask 077; openssl ecparam -name prime256v1 -genkey -noout -out ca.key)
  openssl req -x509 -new -key ca.key -sha256 -days 3650 -out ca.crt \
    -subj "/O=QT Platform/CN=QT Platform Internal CA" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign"
  ok "CA creada (platform/.secrets/tls/ca.crt)"
fi

sans="DNS:vault,DNS:qt-vault,DNS:localhost,IP:127.0.0.1"
for host in ${PLATFORM_HOST//,/ }; do
  if [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then sans+=",IP:${host}"; else sans+=",DNS:${host}"; fi
done

reissue=false
[[ -s vault.crt && -s vault.key ]] || reissue=true
[[ "$(cat san.txt 2>/dev/null)" == "$sans" ]] || reissue=true
if [[ -s vault.crt ]] && ! openssl x509 -checkend 2592000 -noout -in vault.crt >/dev/null; then reissue=true; fi

if [[ "$reissue" == true ]]; then
  info "Emitiendo certificado de Vault (${sans})"
  openssl ecparam -name prime256v1 -genkey -noout -out vault.key
  openssl req -new -key vault.key -out vault.csr -subj "/O=QT Platform/CN=vault"
  printf 'subjectAltName=%s\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n' "$sans" >vault.ext
  openssl x509 -req -in vault.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
    -out vault.crt -days 825 -sha256 -extfile vault.ext 2>/dev/null
  # Legible por el usuario "vault" del contenedor (se monta archivo por archivo;
  # la carpeta .secrets sigue protegida en el host).
  chmod 644 vault.key vault.crt
  rm -f vault.csr vault.ext
  echo "$sans" >san.txt
  touch .reissued
  ok "Certificado de Vault emitido"
fi

base64 -w0 ca.crt >ca.b64
ok "PKI lista (CA: platform/.secrets/tls/ca.crt)"
