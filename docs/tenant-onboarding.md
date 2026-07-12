# Tenant onboarding

Onboarding a team onto the platform is a pull request — no cluster access, no
Argo CD configuration change, and nothing applied by hand. The tenants
ApplicationSet discovers every `tenants/<name>/config.json` in this repository
and creates one Argo CD Application per tenant, pointing at the `manifests/`
directory beside the config file.

## What a tenant looks like

```
tenants/
  team-alpha/
    config.json            # tenant registration (discovered by the ApplicationSet)
    manifests/             # the tenant's workload, applied by Argo CD
      kustomization.yaml
      deployment.yaml
      service.yaml
```

## Step 1 — register the tenant

Create `tenants/<name>/config.json`. All three keys are required; a missing key
fails generation loudly by design.

```json
{
  "tenant": "team-beta",
  "namespace": "team-beta",
  "environment": "dev"
}
```

| Key | Meaning |
|-----|---------|
| `tenant` | Short, DNS-safe name. Used in the Application name (`tenant-<tenant>`) and as a label. |
| `namespace` | Destination namespace for the workload. Created automatically; must be outside the control-plane and addon namespaces. |
| `environment` | Informational label (for example `dev`, `staging`, `prod`). |

## Step 2 — add the workload manifests

Put the tenant's Kubernetes manifests under `tenants/<name>/manifests/`, fronted
by a `kustomization.yaml`. Manifests are validated in CI (kustomize build +
kubeconform) and must satisfy the platform policy checks:

- Every workload container sets CPU and memory **requests and limits**.
- Pod templates set `runAsNonRoot: true`; containers set
  `allowPrivilegeEscalation: false` and drop all Linux capabilities.
- Use a pinned image tag (never `:latest`).

A minimal, policy-compliant deployment:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  labels:
    app.kubernetes.io/name: web
spec:
  replicas: 2
  selector:
    matchLabels:
      app.kubernetes.io/name: web
  template:
    metadata:
      labels:
        app.kubernetes.io/name: web
    spec:
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: web
          image: nginxinc/nginx-unprivileged:1.27.3-alpine
          ports:
            - name: http
              containerPort: 8080
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
          readinessProbe:
            httpGet:
              path: /
              port: http
          livenessProbe:
            httpGet:
              path: /
              port: http
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 128Mi
```

## Step 3 — open the pull request

Push the branch and open a pull request. CI validates the manifests and runs the
policy checks. On merge to `main`:

1. The tenants ApplicationSet picks up the new `config.json`.
2. Argo CD creates the `tenant-<name>` Application in the `tenants` project.
3. The workload reconciles into its namespace (sync wave `30`, after all cluster
   addons are available), and self-heals from there.

No manual sync is required — `automated` sync with prune and self-heal is enabled
on every tenant Application.

## What tenants may and may not do

Tenant Applications are assigned to the `tenants` AppProject, which enforces:

- **Source** — only this repository.
- **Destinations** — any namespace **except** the control-plane and addon
  namespaces (`argocd`, `kube-system`, `kube-node-lease`, `kube-public`,
  `cert-manager`, `external-dns`, `argo-rollouts`).
- **No cluster-scoped resources** — the cluster-resource allow-list is empty, so
  a tenant cannot create CRDs, ClusterRoles, or other cluster-wide objects.
- **No quota tampering** — `ResourceQuota` and `LimitRange` are blocked so a
  tenant cannot raise its own limits.

Requests that fall outside these boundaries are rejected by Argo CD at sync time.

## Progressive delivery (optional)

A tenant that wants gradual rollouts can define an Argo Rollouts `Rollout`
instead of a `Deployment`, following the canary pattern in `apps/sample/`
(stable/canary Services + an `AnalysisTemplate` gating each step on success rate
and latency). The Argo Rollouts controller is installed cluster-wide as an addon,
so no extra setup is needed.

## Offboarding

Delete the `tenants/<name>/` directory in a pull request. On merge, the
ApplicationSet drops the tenant, the finalizer cascades the deletion, and the
Application plus everything it deployed is pruned cleanly.
