{{/*
Derived cluster values — computed from values.yaml
*/}}

{{- define "ctf.keycloakHost" -}}
keycloak-{{ .Values.namespace }}.{{ .Values.appsDomain }}
{{- end }}

{{- define "ctf.keycloakUrl" -}}
https://{{ include "ctf.keycloakHost" . }}
{{- end }}

{{- define "ctf.keycloakIssuer" -}}
{{ include "ctf.keycloakUrl" . }}/realms/{{ .Values.realmName }}
{{- end }}

{{- define "ctf.keycloakTokenUrl" -}}
{{ include "ctf.keycloakIssuer" . }}/protocol/openid-connect/token
{{- end }}

{{- define "ctf.inferenceUrl" -}}
http://{{ .Values.inference.host }}{{ .Values.inference.path }}
{{- end }}
