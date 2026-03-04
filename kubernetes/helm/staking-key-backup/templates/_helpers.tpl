{{/*
Expand the name of the chart.
*/}}
{{- define "staking-key-backup.name" -}}
{{- default "staking-key-backup" .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "staking-key-backup.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default "staking-key-backup" .Values.nameOverride }}
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
{{- define "staking-key-backup.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "staking-key-backup.labels" -}}
helm.sh/chart: {{ include "staking-key-backup.chart" . }}
{{ include "staking-key-backup.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/component: backup
{{- end }}

{{/*
Selector labels
*/}}
{{- define "staking-key-backup.selectorLabels" -}}
app.kubernetes.io/name: staking-key-backup
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "staking-key-backup.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "staking-key-backup.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Backup image based on provider
*/}}
{{- define "staking-key-backup.image" -}}
{{- if eq .Values.storage.provider "gcs" }}
{{- printf "%s:%s" .Values.gcsImage.repository .Values.gcsImage.tag }}
{{- else }}
{{- printf "%s:%s" .Values.image.repository .Values.image.tag }}
{{- end }}
{{- end }}

{{/*
Image pull policy based on provider
*/}}
{{- define "staking-key-backup.imagePullPolicy" -}}
{{- if eq .Values.storage.provider "gcs" }}
{{- .Values.gcsImage.pullPolicy }}
{{- else }}
{{- .Values.image.pullPolicy }}
{{- end }}
{{- end }}
