{{/*
Expand the name of the chart.
*/}}
{{- define "safe.name" -}}
{{- default "safe" .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "safe.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default "safe" .Values.nameOverride }}
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
{{- define "safe.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "safe.labels" -}}
helm.sh/chart: {{ include "safe.chart" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Config Service labels
*/}}
{{- define "safe.cfg.labels" -}}
{{ include "safe.labels" . }}
{{ include "safe.cfg.selectorLabels" . }}
app.kubernetes.io/component: config-service
{{- end }}

{{- define "safe.cfg.selectorLabels" -}}
app.kubernetes.io/name: safe-cfg
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Transaction Service labels
*/}}
{{- define "safe.txs.labels" -}}
{{ include "safe.labels" . }}
{{ include "safe.txs.selectorLabels" . }}
app.kubernetes.io/component: transaction-service
{{- end }}

{{- define "safe.txs.selectorLabels" -}}
app.kubernetes.io/name: safe-txs
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
TXS Worker labels
*/}}
{{- define "safe.txsWorker.labels" -}}
{{ include "safe.labels" . }}
{{ include "safe.txsWorker.selectorLabels" . }}
app.kubernetes.io/component: txs-worker
{{- end }}

{{- define "safe.txsWorker.selectorLabels" -}}
app.kubernetes.io/name: safe-txs-worker
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
TXS Scheduler labels
*/}}
{{- define "safe.txsScheduler.labels" -}}
{{ include "safe.labels" . }}
{{ include "safe.txsScheduler.selectorLabels" . }}
app.kubernetes.io/component: txs-scheduler
{{- end }}

{{- define "safe.txsScheduler.selectorLabels" -}}
app.kubernetes.io/name: safe-txs-scheduler
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Client Gateway labels
*/}}
{{- define "safe.cgw.labels" -}}
{{ include "safe.labels" . }}
{{ include "safe.cgw.selectorLabels" . }}
app.kubernetes.io/component: client-gateway
{{- end }}

{{- define "safe.cgw.selectorLabels" -}}
app.kubernetes.io/name: safe-cgw
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
UI labels
*/}}
{{- define "safe.ui.labels" -}}
{{ include "safe.labels" . }}
{{ include "safe.ui.selectorLabels" . }}
app.kubernetes.io/component: ui
{{- end }}

{{- define "safe.ui.selectorLabels" -}}
app.kubernetes.io/name: safe-ui
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Redis labels
*/}}
{{- define "safe.redis.labels" -}}
{{ include "safe.labels" . }}
{{ include "safe.redis.selectorLabels" . }}
app.kubernetes.io/component: redis
{{- end }}

{{- define "safe.redis.selectorLabels" -}}
app.kubernetes.io/name: safe-redis
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
PostgreSQL CFG/TXS labels
*/}}
{{- define "safe.postgresCfgTxs.labels" -}}
{{ include "safe.labels" . }}
{{ include "safe.postgresCfgTxs.selectorLabels" . }}
app.kubernetes.io/component: postgres-cfg-txs
{{- end }}

{{- define "safe.postgresCfgTxs.selectorLabels" -}}
app.kubernetes.io/name: safe-postgres-cfg-txs
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
PostgreSQL CGW labels
*/}}
{{- define "safe.postgresCgw.labels" -}}
{{ include "safe.labels" . }}
{{ include "safe.postgresCgw.selectorLabels" . }}
app.kubernetes.io/component: postgres-cgw
{{- end }}

{{- define "safe.postgresCgw.selectorLabels" -}}
app.kubernetes.io/name: safe-postgres-cgw
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
RabbitMQ labels
*/}}
{{- define "safe.rabbitmq.labels" -}}
{{ include "safe.labels" . }}
{{ include "safe.rabbitmq.selectorLabels" . }}
app.kubernetes.io/component: rabbitmq
{{- end }}

{{- define "safe.rabbitmq.selectorLabels" -}}
app.kubernetes.io/name: safe-rabbitmq
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Config Service internal URL (for CGW to reach CFG)
*/}}
{{- define "safe.cfg.internalUrl" -}}
http://{{ include "safe.fullname" . }}-cfg:8000
{{- end }}

{{/*
Transaction Service internal URL (for CGW to reach TXS)
*/}}
{{- define "safe.txs.internalUrl" -}}
http://{{ include "safe.fullname" . }}-txs:8888
{{- end }}

{{/*
CGW internal URL (for CFG webhook flush)
*/}}
{{- define "safe.cgw.internalUrl" -}}
http://{{ include "safe.fullname" . }}-cgw:3000
{{- end }}

{{/*
Redis URL
*/}}
{{- define "safe.redis.url" -}}
redis://{{ include "safe.fullname" . }}-redis:6379/0
{{- end }}

{{/*
RabbitMQ URL
*/}}
{{- define "safe.rabbitmq.url" -}}
amqp://{{ .Values.rabbitmq.user }}:{{ .Values.rabbitmq.password }}@{{ include "safe.fullname" . }}-rabbitmq:5672//
{{- end }}

{{/*
PostgreSQL CFG/TXS host
*/}}
{{- define "safe.postgresCfgTxs.host" -}}
{{ include "safe.fullname" . }}-postgres-cfg-txs
{{- end }}

{{/*
PostgreSQL CGW host
*/}}
{{- define "safe.postgresCgw.host" -}}
{{ include "safe.fullname" . }}-postgres-cgw
{{- end }}

{{/*
TXS DATABASE_URL
*/}}
{{- define "safe.txs.databaseUrl" -}}
postgres://{{ .Values.postgres.cfgTxs.user }}:{{ .Values.postgres.cfgTxs.password }}@{{ include "safe.postgresCfgTxs.host" . }}:5432/{{ .Values.postgres.cfgTxs.txsDatabase }}
{{- end }}

{{/*
CFG database connection string (uses separate POSTGRES_* vars, not DATABASE_URL)
*/}}
{{- define "safe.cfg.postgresHost" -}}
{{ include "safe.postgresCfgTxs.host" . }}
{{- end }}

{{/*
External gateway URL for UI. Uses ingress host if available, otherwise ClusterIP.
*/}}
{{- define "safe.gatewayUrl" -}}
{{- if and .Values.ingress.enabled .Values.ingress.host }}
{{- if .Values.ingress.tls }}https{{- else }}http{{- end }}://{{ .Values.ingress.host }}/cgw
{{- else }}
/cgw
{{- end }}
{{- end }}
