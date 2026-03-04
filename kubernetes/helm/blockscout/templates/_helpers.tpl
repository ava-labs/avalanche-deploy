{{/*
Expand the name of the chart.
*/}}
{{- define "blockscout.name" -}}
{{- default "blockscout" .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "blockscout.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default "blockscout" .Values.nameOverride }}
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
{{- define "blockscout.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "blockscout.labels" -}}
helm.sh/chart: {{ include "blockscout.chart" . }}
{{ include "blockscout.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "blockscout.selectorLabels" -}}
app.kubernetes.io/name: blockscout
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Backend selector labels
*/}}
{{- define "blockscout.backendSelectorLabels" -}}
{{ include "blockscout.selectorLabels" . }}
app.kubernetes.io/component: backend
{{- end }}

{{/*
Frontend selector labels
*/}}
{{- define "blockscout.frontendSelectorLabels" -}}
{{ include "blockscout.selectorLabels" . }}
app.kubernetes.io/component: frontend
{{- end }}

{{/*
PostgreSQL selector labels
*/}}
{{- define "blockscout.postgresSelectorLabels" -}}
{{ include "blockscout.selectorLabels" . }}
app.kubernetes.io/component: postgres
{{- end }}

{{/*
Redis selector labels
*/}}
{{- define "blockscout.redisSelectorLabels" -}}
{{ include "blockscout.selectorLabels" . }}
app.kubernetes.io/component: redis
{{- end }}

{{/*
Smart Contract Verifier selector labels
*/}}
{{- define "blockscout.verifierSelectorLabels" -}}
{{ include "blockscout.selectorLabels" . }}
app.kubernetes.io/component: smart-contract-verifier
{{- end }}

{{/*
Visualizer selector labels
*/}}
{{- define "blockscout.visualizerSelectorLabels" -}}
{{ include "blockscout.selectorLabels" . }}
app.kubernetes.io/component: visualizer
{{- end }}

{{/*
Stats selector labels
*/}}
{{- define "blockscout.statsSelectorLabels" -}}
{{ include "blockscout.selectorLabels" . }}
app.kubernetes.io/component: stats
{{- end }}

{{/*
Sig-provider selector labels
*/}}
{{- define "blockscout.sigProviderSelectorLabels" -}}
{{ include "blockscout.selectorLabels" . }}
app.kubernetes.io/component: sig-provider
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "blockscout.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "blockscout.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Database URL for internal PostgreSQL
*/}}
{{- define "blockscout.databaseUrl" -}}
{{- if .Values.postgres.enabled -}}
postgresql://{{ .Values.postgres.user }}:$(DB_PASSWORD)@{{ include "blockscout.fullname" . }}-postgres:{{ .Values.postgres.port }}/{{ .Values.postgres.database }}
{{- else -}}
postgresql://{{ .Values.externalDatabase.user }}:$(DB_PASSWORD)@{{ .Values.externalDatabase.host }}:{{ .Values.externalDatabase.port }}/{{ .Values.externalDatabase.database }}
{{- end -}}
{{- end }}

{{/*
Database password - use postgres.password or externalDatabase.password
*/}}
{{- define "blockscout.databasePassword" -}}
{{- if .Values.postgres.enabled -}}
{{- .Values.postgres.password | default (randAlphaNum 32) -}}
{{- else -}}
{{- .Values.externalDatabase.password -}}
{{- end -}}
{{- end }}

{{/*
Secret key base (auto-generated if empty)
*/}}
{{- define "blockscout.secretKeyBase" -}}
{{- .Values.secretKeyBase | default (randAlphaNum 64) -}}
{{- end }}

{{/*
Backend trace URL (defaults to RPC URL if not set)
*/}}
{{- define "blockscout.traceUrl" -}}
{{- .Values.l1.traceUrl | default .Values.l1.rpcUrl -}}
{{- end }}
