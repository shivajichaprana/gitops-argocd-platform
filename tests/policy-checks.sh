#!/usr/bin/env bash
#
# Manifest policy checks for the GitOps repository.
#
# Enforces two conventions across the Kubernetes and Argo CD manifests that the
# platform relies on and that a rendered kustomize/kubeconform pass cannot catch
# on its own:
#
#   1. Sync-wave ordering — every Argo CD Application, ApplicationSet, and
#      AppProject must declare an `argocd.argoproj.io/sync-wave` annotation so
#      that reconciliation order is explicit rather than incidental. For an
#      ApplicationSet the annotation lives on the generated Application template
#      (`spec.template.metadata.annotations`); for Applications/AppProjects it
#      lives on the object itself (`metadata.annotations`).
#
#   2. Resource bounds + Pod hardening — every fully-defined workload container
#      (one that declares an `image`, i.e. not an upstream strategic-merge
#      patch fragment) must set CPU/memory requests and limits, disable
#      privilege escalation, and drop all Linux capabilities; its Pod template
#      must run as non-root.
#
# The script is dependency-light: Bash plus python3 with PyYAML (both present in
# CI and any standard toolbox). It scans the whole working tree by default, or a
# directory passed as the first argument. Exit code is non-zero on any violation
# so it can gate a pipeline.
#
set -euo pipefail

ROOT="${1:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

if ! command -v python3 >/dev/null 2>&1; then
  echo "policy-checks: python3 is required but was not found on PATH" >&2
  exit 2
fi

python3 - "$ROOT" <<'PY'
import glob
import os
import sys

try:
    import yaml
except ImportError:
    sys.stderr.write("policy-checks: PyYAML is required (pip install pyyaml)\n")
    sys.exit(2)

root = sys.argv[1]

# Argo CD control-plane objects that must carry an explicit sync-wave.
SYNC_WAVE_KINDS = {"Application", "ApplicationSet", "AppProject"}
# Workload kinds whose Pod templates carry containers we harden.
WORKLOAD_KINDS = {"Deployment", "StatefulSet", "DaemonSet", "Rollout", "Job", "CronJob"}
SYNC_WAVE_ANNOTATION = "argocd.argoproj.io/sync-wave"

violations = []
checked_waves = 0
checked_containers = 0


def rel(path):
    return os.path.relpath(path, root)


def annotations_of(meta):
    if not isinstance(meta, dict):
        return {}
    ann = meta.get("annotations")
    return ann if isinstance(ann, dict) else {}


def check_sync_wave(path, doc, kind):
    global checked_waves
    if kind == "ApplicationSet":
        template = (((doc.get("spec") or {}).get("template")) or {})
        ann = annotations_of(template.get("metadata"))
        where = "spec.template.metadata.annotations"
    else:
        ann = annotations_of(doc.get("metadata"))
        where = "metadata.annotations"
    checked_waves += 1
    if SYNC_WAVE_ANNOTATION not in ann:
        violations.append(
            f"{rel(path)}: {kind} '{name_of(doc)}' is missing "
            f"{SYNC_WAVE_ANNOTATION} ({where})"
        )


def pod_template_spec(doc, kind):
    spec = doc.get("spec") or {}
    if kind == "CronJob":
        spec = ((spec.get("jobTemplate") or {}).get("spec")) or {}
    tmpl = (spec.get("template") or {}).get("spec") or {}
    return tmpl


def check_workload(path, doc, kind):
    global checked_containers
    pod = pod_template_spec(doc, kind)
    pod_sec = pod.get("securityContext") or {}
    name = name_of(doc)
    containers = list(pod.get("containers") or []) + list(pod.get("initContainers") or [])
    for c in containers:
        if not isinstance(c, dict) or "image" not in c:
            # A fragment without an image is a strategic-merge patch over an
            # upstream object, not a workload we own end-to-end. Skip it.
            continue
        checked_containers += 1
        cname = c.get("name", "<unnamed>")
        loc = f"{rel(path)}: {kind} '{name}' container '{cname}'"

        res = c.get("resources") or {}
        req = res.get("requests") or {}
        lim = res.get("limits") or {}
        for tier, block in (("requests", req), ("limits", lim)):
            for key in ("cpu", "memory"):
                if key not in block:
                    violations.append(f"{loc} is missing resources.{tier}.{key}")

        csec = c.get("securityContext") or {}
        if csec.get("allowPrivilegeEscalation") is not False:
            violations.append(f"{loc} must set securityContext.allowPrivilegeEscalation: false")
        drop = ((csec.get("capabilities") or {}).get("drop")) or []
        if "ALL" not in drop:
            violations.append(f"{loc} must drop ALL capabilities")

        if pod_sec.get("runAsNonRoot") is not True:
            violations.append(
                f"{loc}: Pod template must set securityContext.runAsNonRoot: true"
            )


def name_of(doc):
    return (doc.get("metadata") or {}).get("name", "<unnamed>")


yaml_files = sorted(
    glob.glob(os.path.join(root, "**", "*.yaml"), recursive=True)
    + glob.glob(os.path.join(root, "**", "*.yml"), recursive=True)
)
yaml_files = [f for f in yaml_files if os.sep + ".git" + os.sep not in f]

for path in yaml_files:
    try:
        docs = list(yaml.safe_load_all(open(path, encoding="utf-8")))
    except yaml.YAMLError as exc:
        violations.append(f"{rel(path)}: YAML parse error: {exc}")
        continue
    for doc in docs:
        if not isinstance(doc, dict):
            continue
        kind = doc.get("kind")
        if kind in SYNC_WAVE_KINDS:
            check_sync_wave(path, doc, kind)
        if kind in WORKLOAD_KINDS:
            check_workload(path, doc, kind)

print(
    f"policy-checks: scanned {len(yaml_files)} manifest file(s); "
    f"verified {checked_waves} sync-wave annotation(s) and "
    f"{checked_containers} workload container(s)."
)

if violations:
    print(f"\npolicy-checks: FAILED with {len(violations)} violation(s):")
    for v in violations:
        print(f"  - {v}")
    sys.exit(1)

print("policy-checks: PASSED — all manifests satisfy sync-wave and workload policies.")
PY
