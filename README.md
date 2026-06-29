# argocd-bootstrap

A **template repository** for bootstrapping and self-managing
[Argo CD](https://argo-cd.readthedocs.io/) with GitOps — similar in spirit to
[`argocd-autopilot`](https://github.com/argoproj-labs/argocd-autopilot), but
plain Kustomize + `kubectl`, no extra CLI to install.

Its layout follows [`argocd-autopilot`](https://github.com/argoproj-labs/argocd-autopilot)
(`bootstrap/` + `projects/` + a `cluster-resources` ApplicationSet), applied
directly with `kubectl` — no autopilot CLI. Workloads enter through the
**app-of-apps "roots"** pattern rather than a directory-generator ApplicationSet.
Clone it, point it at your own git repo, run `make`, and you get an Argo CD that
**manages itself and everything else from git**:

- The Argo CD install is itself an Argo CD `Application` — bump a version, commit, and it upgrades itself.
- A `root` Application manages the projects under `projects/`: `default`, `roots`, and `cluster-addons`.
- The `cluster-resources` ApplicationSet (in the **default** project) manages cluster-scoped resources per cluster (the `in-cluster` folder = the cluster Argo CD runs in).
- The **roots** project holds app-of-apps root Applications; each points at a directory under `roots/` that fans out into child Applications.
- The **cluster-addons** project scopes add-ons synced to every cluster; drop ApplicationSets under `roots/cluster-addons/` and the `cluster-addons-root` applies them.

## How it works

```
this repo (your gitops root)
│
├── make init ─────► renders GIT_REPO / ARGOCD_VERSION into the manifests
│   git push           (you commit + push — the repo now holds the real values)
│
├── make install ──► creates namespace + repo secret, server-side applies
│                    bootstrap/argo-cd, then the argo-cd / root / cluster-resources objects
│
└── from then on, Argo CD reads THIS repo from git:
        argo-cd            Application     ─► syncs bootstrap/argo-cd     (manages its own install)
        root               Application     ─► syncs projects/             (default, roots, cluster-addons)
        cluster-resources  ApplicationSet  ─► one Application per cluster  (cluster-scoped resources)
        <name>-root        Application     ─► syncs roots/<name>/          (app-of-apps fan-out)
```

Because Argo CD reads the manifests back **from git**, the repo URL must be
baked into them. `make init` does that substitution; you commit and push the
result *before* `make install`, so Argo CD reads back exactly the values you
applied and comes up already in sync.

## Layout

```
.
├── Makefile                       # install / bootstrap / day-2 helpers
├── bootstrap/
│   ├── argo-cd/
│   │   ├── kustomization.yaml      # upstream Argo CD install, version-pinned
│   │   └── namespace.yaml          # the argocd namespace
│   ├── argo-cd.yaml                # Application: Argo CD manages its own install
│   ├── root.yaml                   # Application: manages projects/
│   └── cluster-resources.yaml      # ApplicationSet (default project): cluster-scoped resources
├── projects/                       # one file per AppProject (read as a directory by root)
│   ├── default.yaml                # AppProject "default"
│   ├── roots.yaml                  # AppProject "roots" + the app-of-apps root Applications
│   └── cluster-addons.yaml         # AppProject "cluster-addons" (unpopulated)
├── roots/                          # app-of-apps: a directory of children per root
│   └── cluster-addons/             # ApplicationSets for add-ons (add your own; empty here)
│                                   # (the Module 3 exercise adds an `example` root here)
└── cluster-resources/
    ├── in-cluster.json             # cluster descriptor {name, server}
    └── in-cluster/                 # cluster-scoped manifests for the local cluster
```

Neither `projects/` nor `bootstrap/` uses a `kustomization.yaml`: `root` reads
`projects/` as a directory of manifests, and `make bootstrap` applies the three
`bootstrap/*.yaml` objects with `-f`. Only `bootstrap/argo-cd/` keeps a
`kustomization.yaml`, because it pulls the upstream Argo CD install and is where
you patch it (`server.insecure`, etc.).

## Prerequisites

- `kubectl` pointed at the target cluster (cluster-admin)
- `make`, `perl`, `grep` (preinstalled on macOS/Linux)
- A **git repo you control** to hold these manifests (push this template there)
- A **git token** with read access to that repo (e.g. a GitHub PAT)

## Install

The flow is **render → commit → install**, in that order. Rendering and pushing
*before* you install means Argo CD reads back exactly what you applied, so the
very first reconcile is already in sync — no transient drift while the control
plane comes up.

```sh
# 1. Use this template / clone it, then point it at your own repo:
git remote set-url origin https://github.com/you/your-gitops-repo
git push -u origin main

# 2. Render the templates (edits files only — touches nothing in the cluster)
make init \
  GIT_REPO=https://github.com/you/your-gitops-repo \
  ARGOCD_VERSION=v3.2.12

# 3. Publish the rendered manifests so Argo CD reads the same values back
git commit -am "init gitops repo" && git push

# 4. Install: create the repo secret and apply to the cluster
make install \
  GIT_REPO=https://github.com/you/your-gitops-repo \
  GIT_TOKEN=ghp_your_token
```

`make init` renders; `make install` applies. Each underlying phase is also a
target you can run alone:

| Step | Target | What it does |
|------|--------|--------------|
| Render | `init` (→ `manifests`) | Substitutes `GIT_REPO` / `ARGOCD_VERSION` into the manifests in place |
| Guard | `require-rendered` | Refuses to install while placeholders remain (run `init` first) |
| Secret | `repo-secret` | Creates the namespace and a `repository` secret from `GIT_TOKEN` |
| Install | `apply` | `kubectl apply -k bootstrap/argo-cd --server-side` (CRDs + control plane) |
| Wait | `wait-ready` | Waits for argocd-server / repo-server / appset / app-controller |
| Bootstrap | `bootstrap` | Applies the self-managing `argo-cd`, the `root` Application, and the `cluster-resources` ApplicationSet |

`make init` needs `GIT_REPO` (and optionally `ARGOCD_VERSION`); `make install`
needs `GIT_REPO` and `GIT_TOKEN`. The token is the one value never committed to
git — it lives only in the in-cluster repo secret.

### Variables

| Variable | Default | Notes |
|----------|---------|-------|
| `GIT_REPO` | — (required) | HTTPS URL of the repo holding these manifests |
| `GIT_TOKEN` | — (required) | Token Argo CD uses to pull the repo |
| `ARGOCD_VERSION` | `v3.2.12` | Upstream Argo CD release tag to install |
| `GIT_USERNAME` | `git` | Username paired with the token (GitHub ignores it) |
| `ARGOCD_NS` | `argocd` | Namespace to install into |
| `REPO_SECRET_NAME` | `argocd-bootstrap-repo` | Name of the repo-access secret |

### Why server-side apply?

Client-side `kubectl apply` fails on Argo CD's CRDs — the
`last-applied-configuration` annotation exceeds the 262144-byte limit.
Server-side apply avoids that annotation entirely.

## After install

```sh
make password       # initial admin password
make port-forward   # then open https://localhost:8080  (admin / <password>)
make status         # list Applications and ApplicationSets
```

## Extending the template

- **Add a root** — copy the `cluster-addons-root` block in `projects/roots.yaml`,
  pointing it at a new `roots/<name>/` directory. The `root` Application syncs
  `projects/` — no list to update.

- **Add a workload** — drop a child `Application` (or `ApplicationSet`) under that
  root's directory, e.g. `roots/example/<name>.yaml`; the root applies it on the next
  git poll. The Module 3 exercise builds exactly this — an `example` root plus a
  `podinfo` child Application that pulls a Helm chart straight from its repo.

- **Add a cluster add-on** — drop an `ApplicationSet` (or `Application`) under
  `roots/cluster-addons/` — e.g. sealed-secrets, an ingress controller,
  cert-manager. It runs in the `cluster-addons` project and the
  `cluster-addons-root` applies it.

- **Add cluster-scoped resources** — drop manifests (Namespaces, CRDs, repository
  secrets, …) into `cluster-resources/in-cluster/`. To manage another cluster, add
  a `cluster-resources/<cluster>.json` descriptor and a matching
  `cluster-resources/<cluster>/` folder.

- **Customize the install** — patch the Argo CD install via
  `bootstrap/argo-cd/kustomization.yaml` (e.g. a `server.insecure: "true"` patch
  on `argocd-cmd-params-cm` when a TLS-terminating ingress sits in front — a
  commented example is in that file).

## Upgrade Argo CD

The version is **pinned** (`ref=` in `bootstrap/argo-cd/kustomization.yaml`),
which is what you want with GitOps: upgrades are deliberate, reviewable commits —
never silent. To upgrade, bump the `ref=`, commit, and push. The self-managing
`argo-cd` Application syncs the new version, or run `make bootstrap` to apply it
immediately.

### Staying up to date automatically

A weekly chore — [`.github/workflows/argocd-version.yml`](.github/workflows/argocd-version.yml)
— checks for newer stable Argo CD releases and, when one exists, opens a **PR**
bumping the pin (and the Makefile default). You review the linked release notes
and merge; merging lets the `argo-cd` Application roll the control plane forward.
This keeps the pin fresh without ever upgrading unattended. It needs no setup
beyond GitHub Actions being enabled; trigger it on demand from the Actions tab
("Run workflow").

Prefer [Renovate](https://docs.renovatebot.com/)? Drop this in `renovate.json`
instead and disable the workflow:

```json
{
  "customManagers": [
    {
      "customType": "regex",
      "fileMatch": ["bootstrap/argo-cd/kustomization.yaml$", "^Makefile$"],
      "matchStrings": ["ref=(?<currentValue>v[0-9.]+)", "ARGOCD_VERSION\\s*\\??=\\s*(?<currentValue>v[0-9.]+)"],
      "depNameTemplate": "argoproj/argo-cd",
      "datasourceTemplate": "github-releases"
    }
  ]
}
```

## Uninstall

```sh
make uninstall      # deletes Applications (finalizers run), then the install
```
