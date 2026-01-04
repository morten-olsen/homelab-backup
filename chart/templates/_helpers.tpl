{{/*
Expand the name of the chart.
*/}}
{{- define "longhorn-backup.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "longhorn-backup.fullname" -}}
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
{{- define "longhorn-backup.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "longhorn-backup.labels" -}}
helm.sh/chart: {{ include "longhorn-backup.chart" . }}
{{ include "longhorn-backup.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "longhorn-backup.selectorLabels" -}}
app.kubernetes.io/name: {{ include "longhorn-backup.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "longhorn-backup.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "longhorn-backup.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
B2 credentials secret name
*/}}
{{- define "longhorn-backup.b2SecretName" -}}
{{- if .Values.backblaze.existingSecret }}
{{- .Values.backblaze.existingSecret }}
{{- else }}
{{- include "longhorn-backup.fullname" . }}-b2-credentials
{{- end }}
{{- end }}

{{/*
B2 encryption secret name
*/}}
{{- define "longhorn-backup.b2EncryptionSecretName" -}}
{{- if .Values.backblaze.encryption.existingSecret }}
{{- .Values.backblaze.encryption.existingSecret }}
{{- else }}
{{- include "longhorn-backup.fullname" . }}-b2-encryption
{{- end }}
{{- end }}

{{/*
Webhook secret name
*/}}
{{- define "longhorn-backup.webhookSecretName" -}}
{{- if .Values.notifications.existingSecret }}
{{- .Values.notifications.existingSecret }}
{{- else }}
{{- include "longhorn-backup.fullname" . }}-webhook
{{- end }}
{{- end }}

{{/*
NFS backup target URL
*/}}
{{- define "longhorn-backup.nfsTarget" -}}
nfs://{{ .Values.nfs.server }}:{{ .Values.nfs.path }}
{{- end }}
