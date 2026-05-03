{{- define "av-scanner.fullname" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "av-scanner.labels" -}}
app.kubernetes.io/name: av-scanner
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "av-scanner.image" -}}
{{- if .Values.image.registry -}}
{{ .Values.image.registry }}/{{ .Values.image.repository }}:{{ .Values.image.tag }}
{{- else -}}
{{ .Values.image.repository }}:{{ .Values.image.tag }}
{{- end -}}
{{- end }}

{{- define "av-scanner.sshSecretName" -}}
{{ required "sshKey.existingSecret is required" .Values.sshKey.existingSecret }}
{{- end }}

{{- define "av-scanner.inventoryPath" -}}
{{- if .Values.existingInventoryPath -}}
{{ .Values.existingInventoryPath }}
{{- else -}}
/etc/ansible/inventory.yaml
{{- end }}
{{- end }}
