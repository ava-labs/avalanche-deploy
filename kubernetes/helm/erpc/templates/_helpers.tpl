{{/*
Expand the name of the chart.
*/}}
{{- define "erpc.name" -}}
{{- default "erpc" .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "erpc.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default "erpc" .Values.nameOverride }}
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
{{- define "erpc.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "erpc.labels" -}}
helm.sh/chart: {{ include "erpc.chart" . }}
{{ include "erpc.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/component: erpc
{{- end }}

{{/*
Selector labels
*/}}
{{- define "erpc.selectorLabels" -}}
app.kubernetes.io/name: erpc
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
AvalancheGo RPC base URL (for constructing default upstream)
*/}}
{{- define "erpc.avalanchegoUrl" -}}
http://{{ .Values.avalanchego.serviceName }}:{{ .Values.avalanchego.httpPort }}
{{- end }}

{{/*
Default upstream endpoint constructed from avalanchego service and chain ID
*/}}
{{- define "erpc.defaultUpstreamEndpoint" -}}
{{ include "erpc.avalanchegoUrl" . }}/ext/bc/{{ .Values.l1.chainId }}/rpc
{{- end }}
