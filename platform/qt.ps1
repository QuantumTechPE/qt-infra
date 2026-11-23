<#
.SYNOPSIS
  Orquestador de la plataforma QT (Windows / PowerShell).

.DESCRIPTION
  up                                     Vault (TLS) + SonarQube + runners, configurados
  github-app <APP_ID> <CLIENT_ID> <pem>  Guarda la GitHub App en Vault y reinicia los runners
  ssh-key                                Llave SSH para administrar los nodos k3s
  k8s-provision <dev|qa|prod>            Instala/actualiza k3s en los servidores (Ansible)
  k8s-local <dev|qa|prod>                Alternativa sin servidores: cluster k3s en esta PC (k3d)
  k8s-bootstrap <dev|qa|prod>            Vault <-> cluster + Argo CD + GitOps
  gitops-render                          Regenera el contenido inicial de qt-gitops (.generated/)
  secret-list <servicio> <env>           Claves (sin valores) de secret/apps/<servicio>/<env>
  secret-set <servicio> <env> <CLAVE>    Carga un secreto (pide el valor sin mostrarlo)
  secret-generate <servicio> <env> <CLAVE> Genera/rota un valor aleatorio
  xray                                   Dependency-Track (SBOM / CVEs)
  status | logs [servicio] | vault-token | down | destroy

.EXAMPLE
  .\qt.ps1 up

.EXAMPLE
  .\qt.ps1 k8s-provision dev
#>
param(
    [ValidateSet('up', 'github-app', 'ssh-key', 'k8s-provision', 'k8s-local', 'k8s-bootstrap', 'gitops-render', 'secret-list', 'secret-set', 'secret-generate', 'xray', 'status', 'logs', 'vault-token', 'down', 'destroy', 'help')]
    [string]$Command = 'help',
    [string]$Arg1,
    [string]$Arg2,
    [string]$Arg3
)

$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot

function Write-Info([string]$m) { Write-Host "> $m" -ForegroundColor Cyan }
function Write-Ok([string]$m) { Write-Host "OK $m" -ForegroundColor Green }

# Funcion simple (no avanzada): los argumentos tipo --quiet llegan intactos en $args.
# Docker escribe su progreso en stderr: en Windows PowerShell 5.1, si la salida se
# redirige, cada linea se volveria un error fatal. El resultado lo decide solo el
# codigo de salida.
function Invoke-Native {
    $exe = $args[0]
    $rest = @($args | Select-Object -Skip 1)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $exe @rest 2>&1 | ForEach-Object { "$_" }
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
    }
    if ($code -ne 0) { throw "$(Split-Path -Leaf $exe) $($rest -join ' ') fallo (exit $code)" }
}

function Invoke-Compose { Invoke-Native docker compose @args }

# Script del toolbox sin TTY (salida limpia)
function Invoke-Tool {
    $toolArgs = @('run', '--rm', '-T', 'toolbox', 'bash', "/scripts/$($args[0])") + @($args | Select-Object -Skip 1)
    Invoke-Compose @toolArgs
}

# Script del toolbox interactivo (Ansible puede pedir confirmaciones): sin pipe,
# para conservar la terminal.
function Invoke-ToolTty {
    $toolArgs = @('compose', 'run', '--rm', 'toolbox', 'bash', "/scripts/$($args[0])") + @($args | Select-Object -Skip 1)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & docker @toolArgs
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
    }
    if ($code -ne 0) { throw "docker $($toolArgs -join ' ') fallo (exit $code)" }
}

function New-RandomHex([int]$Bytes = 24) {
    $buffer = New-Object byte[] $Bytes
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($buffer)
    return -join ($buffer | ForEach-Object { $_.ToString('x2') })
}

function Initialize-Env {
    if (-not (Test-Path .env)) {
        Copy-Item .env.example .env
        Write-Info 'Creado platform/.env a partir de .env.example'
    }
    $path = (Resolve-Path .env).Path
    $lines = @([System.IO.File]::ReadAllLines($path))
    $changed = $false
    $hasDbPassword = $false
    for ($i = 0; $i -lt $lines.Length; $i++) {
        if ($lines[$i] -match '^SONAR_DB_PASSWORD=') {
            $hasDbPassword = $true
            if ($lines[$i] -match '^SONAR_DB_PASSWORD=\s*$') {
                $lines[$i] = "SONAR_DB_PASSWORD=$(New-RandomHex)"
                $changed = $true
            }
        }
    }
    if (-not $hasDbPassword) {
        $lines += "SONAR_DB_PASSWORD=$(New-RandomHex)"
        $changed = $true
    }
    if ($changed) {
        # UTF-8 sin BOM y finales LF: docker compose lo lee sin sorpresas
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($path, (($lines -join "`n") + "`n"), $utf8NoBom)
    }
    $owner = (($lines | Where-Object { $_ -match '^GITHUB_OWNER=' }) -replace '^GITHUB_OWNER=', '').Trim()
    if ([string]::IsNullOrWhiteSpace($owner) -or $owner -eq 'mi-organizacion') {
        throw 'Edita platform/.env (GITHUB_OWNER, GITHUB_APP_LOGIN, PLATFORM_HOST...) y vuelve a ejecutar'
    }
    foreach ($dir in @('.secrets/runner-approle', '.secrets/tls', '.generated')) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
}

function Assert-Env([string]$Value) {
    if ($Value -notin @('dev', 'qa', 'prod')) { throw "Indica el ambiente: dev | qa | prod" }
}

function Get-EnvValue([string]$Key) {
    $line = [System.IO.File]::ReadAllLines((Resolve-Path .env).Path) | Where-Object { $_ -match "^$Key=" } | Select-Object -First 1
    if ($line) { return ($line -replace "^$Key=", '').Trim() }
    return ''
}

# Completa KEY=valor en .env solo si esta vacio o no existe (no pisa lo que edites)
function Set-EnvDefault([string]$Key, [string]$Value) {
    $path = (Resolve-Path .env).Path
    $lines = @([System.IO.File]::ReadAllLines($path))
    $found = $false
    for ($i = 0; $i -lt $lines.Length; $i++) {
        if ($lines[$i] -match "^$Key=") {
            $found = $true
            if ($lines[$i] -notmatch "^$Key=\s*$") { return }
            $lines[$i] = "$Key=$Value"
        }
    }
    if (-not $found) { $lines += "$Key=$Value" }
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($path, (($lines -join "`n") + "`n"), $utf8NoBom)
    Write-Info "platform/.env: $Key=$Value"
}

# --- Clusteres locales (k3d: k3s dentro de Docker) ---------------------------
$K3dVersion = 'v5.9.0'
$K3dSha256 = '49d0b9c796f5b8ba6f58a1dd5469e8b7b34bf9b6ce9078633eedb2789680a034'
$K3sImage = 'rancher/k3s:v1.37.2-k3s1'
# Puerto HTTP del Ingress de cada ambiente en esta PC (abierto en la LAN) y de la
# API de Kubernetes (solo 127.0.0.1)
$LocalIngressPorts = @{ dev = '8081'; qa = '8082'; prod = '8083' }
$LocalApiPorts = @{ dev = '6551'; qa = '6552'; prod = '6553' }

# k3d fijado por version y verificado por SHA-256 (platform/.bin, ignorado por git)
function Get-K3d {
    $exe = Join-Path $PSScriptRoot '.bin\k3d.exe'
    if (-not (Test-Path $exe)) {
        New-Item -ItemType Directory -Force -Path (Split-Path $exe) | Out-Null
        $tmp = "$exe.download"
        Write-Info "Descargando k3d $K3dVersion"
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -UseBasicParsing -OutFile $tmp `
            -Uri "https://github.com/k3d-io/k3d/releases/download/$K3dVersion/k3d-windows-amd64.exe"
        $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $tmp).Hash.ToLowerInvariant()
        if ($actual -ne $K3dSha256) {
            Remove-Item -Force $tmp
            throw "Checksum de k3d invalido ($actual)"
        }
        Move-Item -Force $tmp $exe
    }
    return $exe
}

switch ($Command) {
    'up' {
        Initialize-Env
        Write-Info 'Construyendo toolbox'
        Invoke-Compose build --quiet vault-unsealer
        Invoke-Tool pki-init.sh
        Write-Info 'Levantando Vault y SonarQube'
        Invoke-Compose up -d vault vault-unsealer sonar-db sonarqube
        if (Test-Path .secrets/tls/.reissued) {
            Invoke-Compose restart vault
            Remove-Item .secrets/tls/.reissued -Force
        }
        Invoke-Tool vault-init.sh
        Invoke-Tool sonar-bootstrap.sh
        Write-Info 'Levantando runners self-hosted'
        Invoke-Compose up -d runner
        Write-Ok 'Plataforma arriba'
        Write-Host '  Vault      https://localhost:8200   (CA: platform/.secrets/tls/ca.crt; token: .\qt.ps1 vault-token)'
        Write-Host '  SonarQube  http://localhost:9000    (admin; password en Vault: secret/platform/sonarqube-admin)'
        Write-Host '  Runners    .\qt.ps1 logs runner     (esperan la GitHub App: .\qt.ps1 github-app ...)'
    }
    'github-app' {
        if (-not $Arg1 -or -not $Arg2 -or -not $Arg3) {
            throw 'uso: .\qt.ps1 github-app <APP_ID> <CLIENT_ID> <ruta-private-key.pem>'
        }
        Initialize-Env
        Copy-Item -LiteralPath $Arg3 -Destination '.secrets/github-app.pem' -Force
        Invoke-Tool vault-github-app.sh $Arg1 $Arg2
        Invoke-Compose up -d --force-recreate runner
        Write-Ok 'Runners reiniciados con la GitHub App'
    }
    'ssh-key' { Initialize-Env; Invoke-Tool ssh-key.sh }
    'secret-list' { Assert-Env $Arg2; Initialize-Env; Invoke-Tool service-secret.sh list $Arg1 $Arg2 }
    'secret-generate' { Assert-Env $Arg2; Initialize-Env; Invoke-Tool service-secret.sh generate $Arg1 $Arg2 $Arg3 }
    'secret-set' {
        Assert-Env $Arg2
        if (-not $Arg1 -or -not $Arg3) { throw 'uso: .\qt.ps1 secret-set <servicio> <dev|qa|prod> <CLAVE>' }
        Initialize-Env
        $secure = Read-Host "Valor de $Arg3 para $Arg1 ($Arg2)" -AsSecureString
        $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
        # El valor viaja por stdin (no queda en el historial ni en la lista de procesos)
        $OutputEncoding = New-Object System.Text.UTF8Encoding $false
        $plain | & docker compose run --rm -T toolbox bash /scripts/service-secret.sh set $Arg1 $Arg2 $Arg3
        if ($LASTEXITCODE -ne 0) { throw 'No se pudo guardar el secreto' }
    }
    'k8s-provision' { Assert-Env $Arg1; Initialize-Env; Invoke-ToolTty k8s-provision.sh $Arg1 }
    'k8s-local' {
        Assert-Env $Arg1
        Initialize-Env
        $k3d = Get-K3d
        $name = "qt-$Arg1"
        $port = $LocalIngressPorts[$Arg1]
        $existing = @(& $k3d cluster list -o json | ConvertFrom-Json | ForEach-Object { $_.name })
        if ($existing -contains $name) {
            Write-Info "El cluster $name ya existe"
        } else {
            Write-Info "Creando cluster $name (k3s $K3sImage; Ingress en el puerto $port)"
            # En la red de la plataforma: Vault y el toolbox lo alcanzan por nombre
            Invoke-Native $k3d cluster create $name --network qt-platform --image $K3sImage `
                --servers 1 --agents 1 --k3s-arg "--tls-san=k3d-$name-server-0@server:0" `
                --api-port "127.0.0.1:$($LocalApiPorts[$Arg1])" -p "${port}:80@loadbalancer" `
                --kubeconfig-switch-context=false --wait --timeout 300s
        }
        # kubeconfig para el toolbox: API por el nombre del nodo dentro de la red Docker
        $kubeconfig = (& $k3d kubeconfig get $name) -join "`n"
        $kubeconfig = $kubeconfig -replace 'server: https://\S+', "server: https://k3d-$name-server-0:6443"
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText((Join-Path $PSScriptRoot ".secrets\kubeconfig-$Arg1"), $kubeconfig + "`n", $utf8NoBom)
        $hostIp = (Get-EnvValue 'PLATFORM_HOST').Split(',')[0].Trim()
        $upper = $Arg1.ToUpper()
        Set-EnvDefault "INGRESS_DOMAIN_$upper" "$Arg1.$hostIp.nip.io"
        Set-EnvDefault "INGRESS_PORT_$upper" $port
        Write-Ok "Cluster $name listo (kubeconfig: platform/.secrets/kubeconfig-$Arg1; kubectl --context k3d-$name)"
        Write-Host "  Siguiente: .\qt.ps1 k8s-bootstrap $Arg1   (requiere el repo qt-gitops)"
    }
    'k8s-bootstrap' { Assert-Env $Arg1; Initialize-Env; Invoke-Tool k8s-bootstrap.sh $Arg1 }
    'gitops-render' { Initialize-Env; Invoke-Tool gitops-render.sh }
    'xray' {
        Initialize-Env
        Invoke-Compose --profile xray up -d dtrack-apiserver dtrack-frontend
        Invoke-Tool dtrack-bootstrap.sh
        Write-Ok 'Dependency-Track: http://localhost:8085 (activa la variable de org DTRACK_ENABLED=true)'
    }
    'status' {
        Invoke-Compose --profile xray ps
        # --ssl-no-revoke: Schannel no puede consultar revocacion de una CA privada (sin CRL)
        & curl.exe -s --ssl-no-revoke --cacert .secrets/tls/ca.crt https://127.0.0.1:8200/v1/sys/seal-status
        Write-Host ''
    }
    'logs' {
        if ($Arg1) { Invoke-Compose --profile xray logs -f --tail 100 $Arg1 }
        else { Invoke-Compose --profile xray logs -f --tail 100 }
    }
    'vault-token' {
        if (-not (Test-Path .secrets/vault-init.json)) { throw 'Vault no esta inicializado' }
        (Get-Content .secrets/vault-init.json -Raw | ConvertFrom-Json).root_token
    }
    'down' { Invoke-Compose --profile xray down }
    'destroy' {
        $answer = Read-Host "Esto BORRA Vault, SonarQube y Dependency-Track (datos y secretos). Escribe 'destruir'"
        if ($answer -ne 'destruir') { throw 'Cancelado' }
        Invoke-Compose --profile xray --profile tools down -v
        Remove-Item -Recurse -Force .secrets, .generated -ErrorAction SilentlyContinue
        Write-Ok 'Plataforma eliminada'
    }
    default { Get-Help $PSCommandPath -Detailed }
}
