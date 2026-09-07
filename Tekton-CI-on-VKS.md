# Tekton CI on VKS

**Detailed Technical Reference & Implementation Guide**

> CI (build) track only — Kubernetes-native Pipelines using Tekton CRDs
>
> Companion to the *Modern Applications CI/CD Stack on VKS Implementation Guide* (Argo CD / GitOps track)

| Property | Baseline |
|---|---|
| Target platform | vSphere Kubernetes Service (VKS) / Kubernetes — dedicated CI-VKS cluster |
| Document scope | CI (build) track only — GitOps/CD is covered in the companion Argo CD guide |
| CI engine | Tekton Pipelines + Tekton Triggers |
| Build strategy | Cloud Native Buildpacks (Pack) as default; BuildKit when a Dockerfile is present |
| Trigger model | Webhook → EventListener → TriggerBinding/TriggerTemplate → PipelineRun |
| Registry handoff | Harbor (scan + sign target for the built OCI image) |
| Dashboard / CLI | Tekton Dashboard (optional) + `tkn` CLI |
| Document date | 2026-09-04 |

> **Scope:** This document is the CI/build-track technical reference for Tekton on VKS: architecture, the CRD model it is built on, sample infrastructure and Pipeline manifests, and the official installation commands for Tekton Pipelines, Triggers, Dashboard and CLI. GitOps delivery, Argo CD reconciliation, Istio ingress, TLS and DNS are addressed in the companion Argo CD implementation guide.

[[_TOC_]]

## 1. Executive Summary

Tekton is deployed as the Kubernetes-native CI orchestrator for this platform, running inside a dedicated CI-VKS cluster that is kept separate from the Runtime-VKS cluster used for application delivery. Tekton is a Cloud Native Computing Foundation (CNCF) project that extends the Kubernetes API itself, so Pipelines, Tasks, and their executions are native Kubernetes objects: stored in `etcd`, managed with `kubectl`, and governed by the same RBAC as every other resource on the cluster.

This document is scoped strictly to the CI/build track. A developer commit triggers a webhook, which the EventListener turns into a `PipelineRun`; each step of the Pipeline (source checkout, then Buildpacks or BuildKit) runs in its own isolated Pod, sharing source code through a Workspace backed by a PersistentVolumeClaim. The resulting OCI image is pushed to Harbor for scanning and signing. Everything downstream of Harbor — GitOps repository updates, Argo CD reconciliation, and Istio Gateway ingress — is covered in the companion Argo CD implementation guide and is out of scope here.

> **Architecture flow:**
> Developer Commit → Webhook → EventListener → PipelineRun → Tekton Task Pods (`git-clone` → Buildpacks/BuildKit) → Harbor scan/sign → *(out of scope in this document: GitOps repository → Argo CD → VKS workload → Istio Gateway API)*

## 2. Source Architecture Traceability

The supplied architecture states that Tekton runs as the Kubernetes-native Pipeline orchestrator, that every build step executes in an isolated Pod, that Buildpacks is the default artifact generator with BuildKit reserved for explicit Dockerfile builds, and that CI and runtime are kept on separate VKS clusters. The table below maps each of those statements to the concrete implementation used in this document.

| Decision | Implementation |
|---|---|
| CI orchestration | Tekton on a dedicated CI-VKS cluster; Pipelines, Tasks, PipelineRuns and TaskRuns are Kubernetes CRDs |
| Trigger model | Webhook → EventListener → TriggerBinding/TriggerTemplate → PipelineRun (Tekton Triggers) |
| Build isolation | Every Pipeline step runs in its own Pod; source shared via a Workspace-backed PVC |
| Build strategy | Dockerfile present → BuildKit; otherwise → Buildpacks (matches the Argo CD document's build-selection rule) |
| RBAC | Native Kubernetes namespace RBAC is reused; no separate Tekton permission system |
| CI/runtime separation | Tekton runs on CI-VKS, isolated from the Runtime-VKS cluster that Argo CD manages |
| Registry handoff | Resulting OCI image is pushed to Harbor for vulnerability scanning and signing |
| Scope boundary | GitOps update, Argo CD sync, and Istio/ingress routing are out of scope for this document |

The source also describes the downstream lifecycle — Harbor governance and secure routing — which is covered in full in the companion Argo CD implementation guide, not repeated here.

## 3. Target VKS Topology

| Zone | Components | Purpose |
|---|---|---|
| App source repo | Git repository + webhook | Commit trigger source for the CI Pipeline |
| CI VKS | Tekton Pipelines, Tekton Triggers, EventListener, PipelineRun/TaskRun pods, `git-clone` Task, Buildpacks/BuildKit Task, optional Dashboard | Ephemeral, isolated build execution (this document's scope) |
| Harbor | OCI registry, vulnerability scanning, image signing | Build artifact destination; hand-off point to the CD track |
| Runtime VKS / GitOps *(out of scope here)* | Argo CD, apps, Istio, cert-manager, external-dns | Application delivery — detailed in the companion Argo CD guide |

A single VKS cluster is acceptable for a POC, with Tekton and the runtime workloads sharing the same cluster in separate namespaces. For production, keeping CI on its own cluster (as shown above) reduces build blast radius and resource contention, matching the supplied architecture's separation-of-concerns recommendation.

## 4. Tekton Architecture on VKS

Tekton is deployed as the Pipeline Orchestrator inside the dedicated CI-VKS cluster described in [Section 3](#3-target-vks-topology), separate from the Runtime-VKS cluster that runs production application workloads. This isolation limits the blast radius of build activity and allows the CI and runtime environments to scale independently.

```mermaid
%%{init: {'flowchart': {'curve': 'basis'}}}%%
flowchart TD
    Dev["Developer"]
    Repo["App Source Repo (Git)"]

    subgraph CI["CI-VKS Cluster (dedicated build cluster)"]
        direction TB
        Ctrl["Tekton Controller + Webhook<br/>(tekton-pipelines ns)"]
        EL["EventListener<br/>(Tekton Triggers)"]

        subgraph Run["PipelineRun"]
            direction LR
            T1["TaskRun Pod:<br/>git-clone"]
            T2["TaskRun Pod:<br/>buildpacks / buildkit"]
            WS["Shared Workspace<br/>(PVC)"]
            T1 -->|runAfter| T2
            T2 --> WS
        end

        CRDs["Kubernetes CRDs: Pipeline, Task, PipelineRun, TaskRun,<br/>EventListener, TriggerBinding, TriggerTemplate<br/>(stored natively in etcd)"]

        EL -->|creates PipelineRun| T1
        Ctrl -.-> EL
    end

    Harbor["Harbor Registry<br/><br/>- Vulnerability scan<br/>- Image signing"]

    subgraph Runtime["Runtime-VKS Cluster"]
        direction TB
        RT["ArgoCD-managed application workloads<br/>(separate from CI, out of this document's scope)"]
    end

    Dev -->|push code| Repo
    Repo -->|webhook trigger| Ctrl
    WS -->|push OCI image| Harbor

    classDef devNode fill:#dbe9fb,stroke:#3573c9,stroke-width:1px,color:#1a1a1a;
    classDef ciCluster fill:#fbe3e0,stroke:#c0392b,stroke-width:2px,color:#8b1a10;
    classDef ciNode fill:#fbe3e0,stroke:#c0392b,stroke-width:1px,color:#1a1a1a;
    classDef podNode fill:#ffffff,stroke:#c0392b,stroke-width:1px,color:#1a1a1a;
    classDef harborNode fill:#fdf1d6,stroke:#b7860b,stroke-width:1px,color:#1a1a1a;
    classDef runtimeCluster fill:#e2f3e6,stroke:#2e7d4f,stroke-width:2px,color:#1a1a1a;

    class Dev,Repo devNode;
    class CI ciCluster;
    class Ctrl,EL,CRDs ciNode;
    class T1,T2,WS podNode;
    class Harbor harborNode;
    class Runtime runtimeCluster;
```

*Figure 1: Tekton CI Architecture on VKS — Tekton executes all build steps as isolated Kubernetes Pods (Tasks) chained into a Pipeline via CRDs.*

A developer pushes code to the App Source repository. A webhook notifies the EventListener, which creates a `PipelineRun`. Tekton then runs each step of the Pipeline (`git-clone`, then buildpacks/buildkit) as an isolated Pod, sharing source code through a Workspace backed by a PersistentVolumeClaim (PVC). The resulting OCI image is pushed to Harbor for scanning and signing. Everything past this point (GitOps update, Argo CD, ingress) belongs to the CD track and is documented separately.

## 5. Why Tekton

### 5.1 Why We Are Using Tekton in This Project

- **Kubernetes-native** — runs directly on the VKS cluster we already operate, with no separate CI server, VM pool, or agent fleet to patch and maintain.
- **Fits the architecture** — the wider CI/CD design (Buildpacks/BuildKit → Harbor → Argo CD → Istio Gateway) is built around CNCF, Kubernetes-first tooling, and Tekton is the CNCF standard for pipeline orchestration.
- **RBAC reuse** — because Pipelines and Tasks are just Kubernetes objects, existing namespace-level RBAC policies control who can create or trigger builds, with no separate permission system.
- **Isolation and reproducibility** — every build step runs in its own Pod, so one team's build cannot leak state into another's, and a build behaves the same way every time it runs.
- **Elastic scaling** — build load is scheduled and scaled by the same Kubernetes scheduler used for everything else on the cluster, with no manual capacity planning for a separate CI farm.

### 5.2 Why This Technology Over Legacy Tools (Jenkins)

Jenkins remains a valid tool, but for a Kubernetes-first platform like VKS, Tekton has structural advantages:

| Aspect | Jenkins (legacy) | Tekton (this project) |
|---|---|---|
| Execution model | Long-lived controller + static/VM agents or plugin-based Kubernetes agents bolted on afterward | Native Kubernetes Pods created and destroyed per build step — no separate agent fleet |
| Configuration | Groovy-based Jenkinsfile / plugin ecosystem, often UI-managed | Declarative YAML CRDs (Pipeline, Task) managed with `kubectl`, versioned in Git like any other manifest |
| Security / RBAC | Separate Jenkins user/role system layered on top of infrastructure | Reuses native Kubernetes RBAC and namespace boundaries directly |
| Infrastructure footprint | Requires dedicated controller node(s), plugin maintenance, and agent capacity management | No heavy external runner; scales using existing cluster nodes |
| Build isolation | Depends on agent/executor configuration; contamination risk if misconfigured | Every step runs in its own isolated Pod by design (`DEC-CI-02`) |
| Extensibility | Plugin marketplace (large but adds maintenance/security overhead) | Reusable Tasks pulled from the Tekton Catalog/Hub, composed like building blocks |

Net effect: Tekton avoids the heavy external runner infrastructure Jenkins requires and simplifies RBAC integration within VKS namespaces, while giving us build reproducibility through per-step Pod isolation.

## 6. Custom Resource Definitions (CRDs)

A Custom Resource Definition (CRD) extends the standard Kubernetes API so the cluster understands new object types beyond the built-ins (Pod, Deployment, Service, etc.). Once a CRD is installed, Kubernetes treats the new object exactly like a native one: it is stored in `etcd`, managed through `kubectl`, and governed by the same RBAC rules.

Tekton defines its core concepts entirely as CRDs:

- **Pipeline** — the CRD describing an ordered set of Tasks.
- **Task** — the CRD describing one unit of build work (a set of Steps run in one Pod).
- **PipelineRun / TaskRun** — the CRDs representing one actual execution of a Pipeline or Task.
- **EventListener / TriggerBinding / TriggerTemplate** — the CRDs (from Tekton Triggers) that turn a webhook event into a new PipelineRun.

### 6.1 Why This Matters

- **No external dependency** — Tekton needs no separate database or control plane of its own; it reuses the Kubernetes control plane and `etcd` that already exist.
- **Standard tooling** — pipelines are managed with the same `kubectl` commands, GitOps flows, and RBAC policies used for every other Kubernetes resource.
- **Declarative and versionable** — Pipeline/Task definitions are plain YAML, so they can be code-reviewed and stored in Git like any other manifest.

## 7. Sample Infrastructure Manifest (`release.yaml`)

This is the structural deployment manifest that installs the Tekton control plane — the dedicated namespace, the controller's ServiceAccount, and the CRDs the engine needs to operate safely on VKS. In practice this file is applied from the official Tekton release URL; the excerpt below shows the key object types it contains.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: tekton-pipelines
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: tekton-pipelines-controller
  namespace: tekton-pipelines
---
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: pipelines.tekton.dev
spec:
  group: tekton.dev
  names:
    kind: Pipeline
    plural: pipelines
  scope: Namespaced
  versions:
    - name: v1
      served: true
      storage: true
```

Applied with:

```bash
kubectl apply --filename \
  https://storage.googleapis.com/tekton-releases/pipeline/latest/release.yaml

kubectl get pods -n tekton-pipelines
```

## 8. Sample Pipeline Workflow (`pipeline.yaml`)

This declarative Pipeline standardizes the code-to-artifact workflow. It clones the source, then attempts a Dockerfile-less build via Buildpacks (falling back to BuildKit only when a Dockerfile is explicitly present), and the resulting OCI image is pushed toward Harbor.

```yaml
apiVersion: tekton.dev/v1
kind: Pipeline
metadata:
  name: vks-modern-app-pipeline
spec:
  params:
    - name: repo-url
      type: string
    - name: image-reference
      type: string
  workspaces:
    - name: shared-workspace
  tasks:
    - name: fetch-source-code
      taskRef:
        name: git-clone
      workspaces:
        - name: output
          workspace: shared-workspace
      params:
        - name: url
          value: $(params.repo-url)
    - name: build-and-push-artifact
      taskRef:
        name: buildpacks
      runAfter:
        - fetch-source-code
      workspaces:
        - name: source
          workspace: shared-workspace
      params:
        - name: APP_IMAGE
          value: $(params.image-reference)
```

### 8.1 Pipeline Workflow Parameters Explained

| Field | Rationale & Function |
|---|---|
| `params` | Injects variables at runtime (e.g. the Git repo URL, the destination image tag in Harbor) without hardcoding values into the Pipeline definition. |
| `workspaces` | Binds a PVC-backed shared volume to the Pipeline so the `git-clone` Task can write source code to disk that the `buildpacks` Task then reads. |
| `taskRef` | References a prebuilt, standardized Task (e.g. from the Tekton Catalog) instead of redefining build logic from scratch, cutting developer overhead. |
| `runAfter` | Enforces execution order — guarantees the source code is fully cloned before the artifact builder Task starts. |
| `tasks[].name` | A unique label for that step within the Pipeline; referenced by other steps' `runAfter` and by logs/dashboards. |
| `workspaces` (per task) | Maps the Pipeline-level `shared-workspace` to the specific workspace name each Task expects internally (e.g. `output` for `git-clone`, `source` for `buildpacks`). |

### 8.2 Starting a Run Manually (Local Test)

```bash
tkn pipeline start vks-modern-app-pipeline \
  -w name=shared-workspace,claimName=my-pvc \
  -p repo-url=https://github.com/org/sample-app.git \
  -p image-reference=harbor.local/team/sample-app:test

tkn pipelinerun logs -f
```

## 9. Official Release Manifests, Commands & References

All commands below are copied directly from the official Tekton project documentation (tekton.dev) and the `tektoncd` GitHub organization. These are the exact manifests to apply for a clean install — no third-party mirrors.

### 9.1 Tekton Pipelines (Core) — Required

Current official CDN (tekton.dev points here as of 2026):

```bash
kubectl apply --filename \
  https://infra.tekton.dev/tekton-releases/pipeline/latest/release.yaml

kubectl get pods --namespace tekton-pipelines --watch
```

Legacy mirror (still valid, used in most existing docs/tutorials):

```bash
kubectl apply --filename \
  https://storage.googleapis.com/tekton-releases/pipeline/latest/release.yaml
```

Install a specific version instead of `latest`:

```bash
kubectl apply --filename \
  https://infra.tekton.dev/tekton-releases/pipeline/previous/v1.15.1/release.yaml
```

Untagged variant (only if the container runtime doesn't support `image:tag@digest`, e.g. older CRI-O/OpenShift):

```bash
kubectl apply --filename \
  https://infra.tekton.dev/tekton-releases/pipeline/latest/release.notags.yaml
```

### 9.2 Tekton Triggers — Required only for webhook-based auto-trigger

```bash
kubectl apply --filename \
  https://storage.googleapis.com/tekton-releases/triggers/latest/release.yaml

kubectl apply --filename \
  https://storage.googleapis.com/tekton-releases/triggers/latest/interceptors.yaml

kubectl get pods --namespace tekton-pipelines --watch
```

### 9.3 Tekton Dashboard — Optional (visual PipelineRun monitoring)

Read-only mode (default, recommended for shared/production clusters):

```bash
kubectl apply --filename \
  https://infra.tekton.dev/tekton-releases/dashboard/latest/release.yaml
```

Read/write mode (lets you trigger runs from the UI — fine for local testing):

```bash
kubectl apply --filename \
  https://infra.tekton.dev/tekton-releases/dashboard/latest/release-full.yaml
```

Access locally via port-forward:

```bash
kubectl --namespace tekton-pipelines port-forward \
  svc/tekton-dashboard 9097:9097

# then open http://localhost:9097
```

### 9.4 Tekton CLI (`tkn`) — for running/inspecting Pipelines from a terminal

```bash
# macOS (Homebrew)
brew install tektoncd-cli

# Linux (x86_64)
curl -LO https://github.com/tektoncd/cli/releases/download/\
v0.41.0/tkn_0.41.0_Linux_x86_64.tar.gz
tar xvzf tkn_0.41.0_Linux_x86_64.tar.gz -C /usr/local/bin tkn
tkn version
```

> Check the CLI Releases page (link in the reference table below) for the current version number before running the Linux install command.

### 9.5 Verifying the Installation

```bash
kubectl get pods -n tekton-pipelines
kubectl get crd | grep tekton.dev
```

### 9.6 Uninstalling (Rollback / Cleanup)

```bash
kubectl delete --filename \
  https://infra.tekton.dev/tekton-releases/pipeline/latest/release.yaml

kubectl delete --filename \
  https://storage.googleapis.com/tekton-releases/triggers/latest/release.yaml
```

### 9.7 Official References

| Resource | Official URL |
|---|---|
| Tekton Pipelines — Install docs | [tekton.dev/docs/pipelines/install](https://tekton.dev/docs/pipelines/install) |
| Tekton Triggers — Install docs | [tekton.dev/docs/triggers/install](https://tekton.dev/docs/triggers/install) |
| Tekton Dashboard — Install docs | [tekton.dev/docs/dashboard/install](https://tekton.dev/docs/dashboard/install) |
| Tekton Getting Started (Tasks) | [tekton.dev/docs/getting-started/tasks](https://tekton.dev/docs/getting-started/tasks) |
| Tekton Catalog / Hub (reusable Tasks: `git-clone`, `buildpacks`, etc.) | [hub.tekton.dev](https://hub.tekton.dev) |
| Tekton Pipelines source & releases | [github.com/tektoncd/pipeline](https://github.com/tektoncd/pipeline) |
| Tekton Triggers source & releases | [github.com/tektoncd/triggers](https://github.com/tektoncd/triggers) |
| Tekton Dashboard source & releases | [github.com/tektoncd/dashboard](https://github.com/tektoncd/dashboard) |
| Tekton CLI (`tkn`) releases | [github.com/tektoncd/cli/releases](https://github.com/tektoncd/cli/releases) |
| Tekton Operator (managed install/upgrade of all components) | [github.com/tektoncd/operator](https://github.com/tektoncd/operator) |
| CNCF project page | [cncf.io/projects/tekton](https://cncf.io/projects/tekton) |

> **Note:** As of 2026 the Tekton project is migrating its canonical release CDN from `storage.googleapis.com` to `infra.tekton.dev`. Both currently resolve to valid release manifests; `infra.tekton.dev` is what the live tekton.dev documentation shows first, so it is used as primary in this document, with the older domain listed as a working fallback.

## 10. Summary

Tekton gives this project a Kubernetes-native, CRD-based CI engine that removes the need for external build infrastructure, reuses existing RBAC boundaries, and guarantees reproducible, isolated builds per step. The Pipeline shown in [Section 8](#8-sample-pipeline-workflow-pipelineyaml) (clone → build via Buildpacks/BuildKit → push) is the minimum working CI loop that can be validated locally before wiring in Harbor governance, GitOps updates, and Argo CD delivery, which are documented in the companion Argo CD implementation guide.

---

*Document date: 2026-09-04 · CI (build) track only. For GitOps/CD, Argo CD, and Istio ingress, see the companion Argo CD implementation guide.*
