{{/*
Expand the name of the chart.
*/}}
{{- define "banking-application.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "banking-application.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "banking-application.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Common labels.
*/}}
{{- define "banking-application.labels" -}}
helm.sh/chart: {{ include "banking-application.chart" . }}
{{ include "banking-application.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/*
Selector labels.
*/}}
{{- define "banking-application.selectorLabels" -}}
app.kubernetes.io/name: {{ include "banking-application.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Name of the ServiceAccount to use.
*/}}
{{- define "banking-application.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "banking-application.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/*
Fully qualified image reference.
*/}}
{{- define "banking-application.image" -}}
{{- $tag := .Values.image.tag | default .Chart.AppVersion -}}
{{- if .Values.image.registry -}}
{{- printf "%s/%s:%s" .Values.image.registry .Values.image.repository $tag -}}
{{- else -}}
{{- printf "%s:%s" .Values.image.repository $tag -}}
{{- end -}}
{{- end -}}

{{/*
=============================================================================
FAIL-FAST GUARDS - turning runtime failures into deploy-time template errors.

This is the pattern worth extending, because the failures it prevents are the
expensive kind: silent, delayed, and diagnosed deep inside an SDK stack trace.

CURRENT GUARD: workloadIdentity.enabled without a clientId. Without this the chart
renders happily, the pod starts, passes liveness, and then fails on its FIRST Azure
call with AADSTS700016 - minutes later, in a stack trace nobody reads.

THE GUARD THAT SHOULD BE ADDED (docs/02 P0-6) - assert the Workload Identity SUBJECT
matches what the federated credential expects, so a namespace or ServiceAccount
rename cannot silently break authentication:

  {{- if .Values.workloadIdentity.expectedSubject }}
  {{-   $actual := printf "system:serviceaccount:%s:%s" .Release.Namespace (include "banking-application.serviceAccountName" .) }}
  {{-   if ne $actual .Values.workloadIdentity.expectedSubject }}
  {{-     fail (printf "Workload Identity subject mismatch: chart renders %q but the federated credential expects %q" $actual .Values.workloadIdentity.expectedSubject) }}
  {{-   end }}
  {{- end }}

...with expectedSubject passed by the pipeline from a new Terraform output. That
converts AADSTS70021 - the single most common Workload Identity failure in the real
world - from a confusing runtime error into an unmissable deploy-time one.
=============================================================================
*/}}
{{/*
Fail fast on invalid value combinations.
*/}}
{{- define "banking-application.validateValues" -}}
{{- if and .Values.workloadIdentity.enabled (not .Values.workloadIdentity.clientId) -}}
{{- fail "workloadIdentity.enabled is true but workloadIdentity.clientId is not set" -}}
{{- end -}}
{{- end -}}
