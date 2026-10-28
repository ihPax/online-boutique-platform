#!/usr/bin/env bash
# Controlli di policy minimi sui manifest renderizzati, senza dipendenze dal cluster.
# Le stesse regole, in esercizio, andrebbero in un admission controller (Kyverno/Gatekeeper):
# vedi docs/architecture.md, "Sicurezza".
set -euo pipefail
dir="${1:-rendered}"
python3 - "$dir" <<'PY'
import sys, glob, yaml
fail = []
for path in sorted(glob.glob(f"{sys.argv[1]}/*.yaml")):
    for d in yaml.safe_load_all(open(path)):
        if not d:
            continue
        kind, name = d.get("kind"), d.get("metadata", {}).get("name")
        where = f"{path}: {kind}/{name}"
        if kind == "Namespace" and d["metadata"]["name"].startswith("boutique-"):
            lbl = d["metadata"].get("labels", {})
            if lbl.get("pod-security.kubernetes.io/enforce") != "restricted":
                fail.append(f"{where}: manca PSA enforce=restricted")
        if kind != "Deployment":
            continue
        spec = d["spec"]["template"]["spec"]
        if spec.get("automountServiceAccountToken") is not False:
            fail.append(f"{where}: automountServiceAccountToken deve essere false")
        if spec.get("serviceAccountName") in (None, "default"):
            fail.append(f"{where}: serve un ServiceAccount dedicato")
        for c in spec.get("containers", []) + spec.get("initContainers", []):
            img = c["image"]
            tag = img.split("@")[0].rsplit(":", 1)
            if "@" not in img and (len(tag) == 1 or tag[1] == "latest"):
                fail.append(f"{where}/{c['name']}: immagine senza tag o :latest ({img})")
            sc = c.get("securityContext", {})
            if sc.get("allowPrivilegeEscalation") is not False:
                fail.append(f"{where}/{c['name']}: allowPrivilegeEscalation deve essere false")
        for c in spec.get("containers", []):
            if not c.get("resources", {}).get("limits", {}).get("memory"):
                fail.append(f"{where}/{c['name']}: manca limits.memory")
            # Solo per chi espone porte: il loadgenerator è un client puro.
            if c.get("ports") and "readinessProbe" not in c:
                fail.append(f"{where}/{c['name']}: manca readinessProbe")
if fail:
    print("\n".join(fail))
    sys.exit(1)
print("policy-check: ok")
PY
