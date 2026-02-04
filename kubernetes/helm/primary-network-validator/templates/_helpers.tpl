{{/*
Expand the name of the chart.
*/}}
{{- define "primary-network-validator.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "primary-network-validator.fullname" -}}
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
{{- define "primary-network-validator.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "primary-network-validator.labels" -}}
helm.sh/chart: {{ include "primary-network-validator.chart" . }}
{{ include "primary-network-validator.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/component: primary-network
{{- end }}

{{/*
Selector labels
*/}}
{{- define "primary-network-validator.selectorLabels" -}}
app.kubernetes.io/name: primary-network-validator
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "primary-network-validator.serviceAccountName" -}}
{{- if .Values.primary_validator_serviceAccount.create }}
{{- default (include "primary-network-validator.fullname" .) .Values.primary_validator_serviceAccount.name }}
{{- else }}
{{- default "default" .Values.primary_validator_serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Get network ID based on network name
*/}}
{{- define "primary-network-validator.networkId" -}}
{{- if eq .Values.network "mainnet" }}1{{- else }}5{{- end }}
{{- end }}
