{{/* Nombre del servicio */}}
{{- define "qt-service.name" -}}
{{- default .Release.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* ¿Hay una versión para desplegar? (digest presente y válido) */}}
{{- define "qt-service.enabled" -}}
{{- if .Values.image.digest -}}
{{- if not (regexMatch "^sha256:[a-f0-9]{64}$" .Values.image.digest) -}}
{{- fail (printf "image.digest inválido: %q (se espera sha256:<64 hex>)" .Values.image.digest) -}}
{{- end -}}
{{- if not .Values.image.repository -}}
{{- fail "image.repository es obligatorio" -}}
{{- end -}}
{{- if not (has .Values.environment (list "dev" "qa" "prod")) -}}
{{- fail (printf "environment inválido: %q (dev | qa | prod)" .Values.environment) -}}
{{- end -}}
true
{{- end -}}
{{- end -}}

{{- define "qt-service.selectorLabels" -}}
app.kubernetes.io/name: {{ include "qt-service.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "qt-service.labels" -}}
{{ include "qt-service.selectorLabels" . }}
app.kubernetes.io/version: {{ .Values.image.tag | default "unversioned" | replace "+" "_" | trunc 63 | quote }}
app.kubernetes.io/part-of: qt-platform
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
qt.platform/environment: {{ .Values.environment }}
{{- end -}}

{{/* Ruta del secreto en Vault (KV v2, montado en secret/) */}}
{{- define "qt-service.vaultKey" -}}
{{- default (printf "apps/%s/%s" (include "qt-service.name" .) .Values.environment) .Values.secrets.key -}}
{{- end -}}

{{/* Host del Ingress: explícito o <subdomain>.<global.ingressDomain> */}}
{{- define "qt-service.ingressHost" -}}
{{- if .Values.ingress.host -}}
{{- .Values.ingress.host -}}
{{- else if and .Values.ingress.subdomain .Values.global.ingressDomain -}}
{{- printf "%s.%s" .Values.ingress.subdomain .Values.global.ingressDomain -}}
{{- else -}}
{{- fail "ingress: define ingress.host o (ingress.subdomain + global.ingressDomain)" -}}
{{- end -}}
{{- end -}}

{{/* ¿Hay archivos de configuración para montar? */}}
{{- define "qt-service.hasConfigFiles" -}}
{{- if and .Values.configFiles.mountPath .Values.configFiles.files -}}true{{- end -}}
{{- end -}}
