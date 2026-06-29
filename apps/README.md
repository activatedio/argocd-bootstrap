# apps/

Each subdirectory here becomes an Argo CD `Application` in the `default`
project, picked up automatically by the `default` ApplicationSet
(`projects/default.yaml`).

Drop a directory with any source Argo CD's manifest discovery understands —
a `kustomization.yaml`, a Helm chart, or plain YAML manifests — and Argo CD
creates and syncs the Application on its next git poll. No registration step.

```
apps/
└── my-app/
    └── kustomization.yaml
```
