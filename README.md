# gitops-argocd-platform

GitOps control plane for Amazon EKS built on [Argo CD](https://argo-cd.readthedocs.io/):
a declarative, pinned Argo CD installation, an app-of-apps root that owns everything
else in the cluster, ApplicationSets for cluster addons and tenant workloads, and
progressive delivery with Argo Rollouts.

Git is the single source of truth. After the one-time bootstrap below, no manual
`kubectl apply` should ever mutate the cluster — every change lands as a commit,
Argo CD reconciles it, and drift is corrected automatically.

## Repository layout

| Path | Purpose |
|------|---------|
| `bootstrap/argocd/` | Kustomize overlay that installs a pinned Argo CD release with EKS-specific patches |
| `bootstrap/app-of-apps.yaml` | Root Application — the only manifest ever applied by hand |
| `appsets/` | ApplicationSets that stamp out cluster addons and per-tenant applications |
| `tenants/` | Tenant registrations (`config.json`) and workload manifests discovered by the tenants ApplicationSet |
| `apps/` | Workload manifests, including canary Rollouts and analysis templates |
| `projects/` | AppProjects with RBAC boundaries and sync-wave ordering |
| `notifications/` | Argo CD notifications configuration (delivery to chat/webhooks) |
| `docs/` | Architecture and tenant onboarding guides |

## Prerequisites

- An EKS cluster (1.29+) and a kubeconfig context pointing at it
- `kubectl` 1.29+ (`kubectl apply -k` provides the kustomize support used here)
- Cluster-admin access for the initial bootstrap only

## Bootstrap

```bash
# 1. Install Argo CD (namespace, pinned upstream manifest, EKS patches)
kubectl apply -k bootstrap/argocd

# 2. Wait for the control plane to become ready
kubectl -n argocd rollout status deployment/argocd-server --timeout=300s

# 3. Hand the cluster over to GitOps — the root app adopts everything under appsets/
kubectl apply -f bootstrap/app-of-apps.yaml
```

Retrieve the initial admin password (rotate it immediately, then delete the secret):

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

## Version pinning

The Argo CD version is pinned to an exact upstream release tag inside
`bootstrap/argocd/kustomization.yaml`. Upgrades are a one-line diff: bump the tag,
open a pull request, and let the CI manifest validation confirm the build before
merging. Never track a moving branch.

## Design principles

- **Declarative everything** — the bootstrap overlay and the root Application are
  the only objects created imperatively, exactly once.
- **App-of-apps** — a single root Application owns the ApplicationSets, which in
  turn own addons and tenant apps; deleting the root cascades cleanly via finalizers.
- **Pinned supply chain** — upstream manifests are referenced by immutable release
  tag, never `HEAD` or `stable`.
- **Self-healing** — automated sync with prune and self-heal keeps the cluster
  converged with Git; out-of-band changes are reverted.
- **Blast-radius control** — AppProjects restrict which repos, clusters, and
  namespaces each team can deploy to; sync waves order addons before workloads.

## Contributing

Open a Discussion in the repo or comment on a pull request.

## License

MIT — see [LICENSE](LICENSE).
