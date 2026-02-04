{{/*
Expand the name of the chart.
*/}}
{{- define "primary-network-rpc.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "primary-network-rpc.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
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
{{- define "primary-network-rpc.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "primary-network-rpc.labels" -}}
helm.sh/chart: {{ include "primary-network-rpc.chart" . }}
{{ include "primary-network-rpc.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/component: primary-network
{{- end }}

{{/*
Selector labels
*/}}
{{- define "primary-network-rpc.selectorLabels" -}}
app.kubernetes.io/name: primary-network-rpc
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "primary-network-rpc.serviceAccountName" -}}
{{- if .Values.primary_rpc_serviceAccount.create }}
{{- default (include "primary-network-rpc.fullname" .) .Values.primary_rpc_serviceAccount.name }}
{{- else }}
{{- default "default" .Values.primary_rpc_serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Get network ID based on network name
*/}}
{{- define "primary-network-rpc.networkId" -}}
{{- if eq .Values.network "mainnet" }}1{{- else }}5{{- end }}
{{- end }}
