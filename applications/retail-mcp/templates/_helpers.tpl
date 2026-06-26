{{- define "retail-mcp.keycloakHost" -}}
keycloak-{{ .Values.namespace }}.{{ .Values.appsDomain }}
{{- end }}

{{- define "retail-mcp.keycloakUrl" -}}
https://{{ include "retail-mcp.keycloakHost" . }}
{{- end }}

{{- define "retail-mcp.keycloakIssuer" -}}
{{ include "retail-mcp.keycloakUrl" . }}/realms/{{ .Values.realmName }}
{{- end }}

{{- define "retail-mcp.keycloakTokenUrl" -}}
{{ include "retail-mcp.keycloakIssuer" . }}/protocol/openid-connect/token
{{- end }}
