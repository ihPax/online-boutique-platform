{{- define "obe.quota" -}}
{{- $sizes := dict
  "bronze" (dict "reqCpu" "2" "reqMem" "2Gi" "limCpu" "4" "limMem" "4Gi")
  "silver" (dict "reqCpu" "3" "reqMem" "3Gi" "limCpu" "6" "limMem" "6Gi")
  "gold"   (dict "reqCpu" "6" "reqMem" "6Gi" "limCpu" "12" "limMem" "12Gi") -}}
{{- toJson (get $sizes .Values.tier) -}}
{{- end -}}
