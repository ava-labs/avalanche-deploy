{{/*
Expand the name of the chart.
*/}}
{{- define "l1-rpc.name" -}}
{{- default "l1-rpc" .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "l1-rpc.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default "l1-rpc" .Values.nameOverride }}
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
{{- define "l1-rpc.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "l1-rpc.labels" -}}
helm.sh/chart: {{ include "l1-rpc.chart" . }}
{{ include "l1-rpc.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/component: l1
{{- end }}

{{/*
Selector labels
*/}}
{{- define "l1-rpc.selectorLabels" -}}
app.kubernetes.io/name: l1-rpc
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "l1-rpc.serviceAccountName" -}}
{{- if .Values.l1_rpc_serviceAccount.create }}
{{- default (include "l1-rpc.fullname" .) .Values.l1_rpc_serviceAccount.name }}
{{- else }}
{{- default "default" .Values.l1_rpc_serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Network ID based on network name
*/}}
{{- define "l1-rpc.networkId" -}}
{{- if eq .Values.network "mainnet" }}1{{- else }}5{{- end }}
{{- end }}
