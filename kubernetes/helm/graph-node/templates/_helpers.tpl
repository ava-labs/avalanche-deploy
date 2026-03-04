{{/*
Expand the name of the chart.
*/}}
{{- define "graph-node.name" -}}
{{- default "graph-node" .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "graph-node.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default "graph-node" .Values.nameOverride }}
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
{{- define "graph-node.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "graph-node.labels" -}}
helm.sh/chart: {{ include "graph-node.chart" . }}
{{ include "graph-node.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels for graph-node
*/}}
{{- define "graph-node.selectorLabels" -}}
app.kubernetes.io/name: graph-node
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: graph-node
{{- end }}

{{/*
Selector labels for postgres
*/}}
{{- define "graph-node.postgres.selectorLabels" -}}
app.kubernetes.io/name: graph-node
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: postgres
{{- end }}

{{/*
Selector labels for ipfs
*/}}
{{- define "graph-node.ipfs.selectorLabels" -}}
app.kubernetes.io/name: graph-node
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: ipfs
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "graph-node.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "graph-node.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Ethereum RPC URL - use explicit rpcUrl or construct from avalanchego service
*/}}
{{- define "graph-node.ethereumRpcUrl" -}}
{{- if .Values.l1.rpcUrl }}
{{- .Values.l1.rpcUrl }}
{{- else if .Values.avalanchego.serviceName }}
{{- printf "http://%s:%d/ext/bc/%s/rpc" .Values.avalanchego.serviceName (int .Values.avalanchego.httpPort) .Values.l1.chainId }}
{{- else }}
{{- fail "Either l1.rpcUrl or avalanchego.serviceName must be set" }}
{{- end }}
{{- end }}

{{/*
PostgreSQL hostname
*/}}
{{- define "graph-node.postgresHost" -}}
{{- printf "%s-postgres" (include "graph-node.fullname" .) }}
{{- end }}

{{/*
IPFS API URL
*/}}
{{- define "graph-node.ipfsUrl" -}}
{{- printf "%s-ipfs:5001" (include "graph-node.fullname" .) }}
{{- end }}
