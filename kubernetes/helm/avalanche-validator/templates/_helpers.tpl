{{/*
Expand the name of the chart.
*/}}
{{- define "l1-validator.name" -}}
{{- default "l1-validator" .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "l1-validator.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default "l1-validator" .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "l1-validator.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "l1-validator.labels" -}}
helm.sh/chart: {{ include "l1-validator.chart" . }}
{{ include "l1-validator.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/component: l1
{{- end }}

{{/*
Selector labels
*/}}
{{- define "l1-validator.selectorLabels" -}}
app.kubernetes.io/name: l1-validator
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "l1-validator.serviceAccountName" -}}
{{- if .Values.l1_validator_serviceAccount.create }}
{{- default (include "l1-validator.fullname" .) .Values.l1_validator_serviceAccount.name }}
{{- else }}
{{- default "default" .Values.l1_validator_serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Network ID based on network name
*/}}
{{- define "l1-validator.networkId" -}}
{{- if eq .Values.network "mainnet" }}1{{- else }}5{{- end }}
{{- end }}

{{/*
HTTP allowed hosts (--http-allowed-hosts).
AvalancheGo only accepts API requests whose Host header is an IP address,
matches this list exactly (case-insensitive), or when the list contains the
global wildcard "*" — suffix wildcards are NOT supported. Its built-in
default ("localhost") 403-rejects every in-cluster client that reaches the
node via service DNS. Default here: localhost, this release's (headless)
service DNS variants, and the per-pod StatefulSet DNS names for each replica.
*/}}
{{- define "l1-validator.httpAllowedHosts" -}}
{{- if .Values.l1_validator_config.httpAllowedHosts -}}
{{- join "," .Values.l1_validator_config.httpAllowedHosts -}}
{{- else -}}
{{- $svc := include "l1-validator.fullname" . -}}
{{- $ns := .Release.Namespace -}}
{{- $hosts := list "localhost" $svc (printf "%s.%s" $svc $ns) (printf "%s.%s.svc" $svc $ns) (printf "%s.%s.svc.cluster.local" $svc $ns) -}}
{{- range $i := until (int .Values.l1_validator_replicas) -}}
{{- $pod := printf "%s-%d" $svc $i -}}
{{- $hosts = concat $hosts (list (printf "%s.%s" $pod $svc) (printf "%s.%s.%s" $pod $svc $ns) (printf "%s.%s.%s.svc" $pod $svc $ns) (printf "%s.%s.%s.svc.cluster.local" $pod $svc $ns)) -}}
{{- end -}}
{{- join "," $hosts -}}
{{- end -}}
{{- end }}
