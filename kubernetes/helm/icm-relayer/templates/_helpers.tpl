{{/*
Expand the name of the chart.
*/}}
{{- define "icm-relayer.name" -}}
{{- default "icm-relayer" .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "icm-relayer.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default "icm-relayer" .Values.nameOverride }}
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
{{- define "icm-relayer.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "icm-relayer.labels" -}}
helm.sh/chart: {{ include "icm-relayer.chart" . }}
{{ include "icm-relayer.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/component: icm-relayer
{{- end }}

{{/*
Selector labels
*/}}
{{- define "icm-relayer.selectorLabels" -}}
app.kubernetes.io/name: icm-relayer
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "icm-relayer.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "icm-relayer.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
AvalancheGo base URL
*/}}
{{- define "icm-relayer.avalanchegoUrl" -}}
http://{{ .Values.avalanchego.serviceName }}:{{ .Values.avalanchego.httpPort }}
{{- end }}

{{/*
AvalancheGo WebSocket base URL
*/}}
{{- define "icm-relayer.avalanchegoWsUrl" -}}
ws://{{ .Values.avalanchego.serviceName }}:{{ .Values.avalanchego.httpPort }}
{{- end }}

{{/*
C-Chain subnet ID based on network
*/}}
{{- define "icm-relayer.cchainSubnetId" -}}
{{- if eq .Values.network "mainnet" }}{{ .Values.cchain.mainnet.subnetId }}{{- else }}{{ .Values.cchain.fuji.subnetId }}{{- end }}
{{- end }}

{{/*
C-Chain blockchain ID based on network
*/}}
{{- define "icm-relayer.cchainBlockchainId" -}}
{{- if eq .Values.network "mainnet" }}{{ .Values.cchain.mainnet.blockchainId }}{{- else }}{{ .Values.cchain.fuji.blockchainId }}{{- end }}
{{- end }}
