## Tekton CI on VKS

*Detailed Technical Reference & Implementation Guide*

*CI (build) track only — Kubernetes-native Pipelines using Tekton CRDs, extended with native Software Supply Chain Security (SBOM generation, image signing, and attestation)*

*Companion to the "Modern Applications CI/CD Stack on VKS" Implementation Guide (Argo CD / GitOps track)*
---
### Executive Summary

Tekton is deployed as the Kubernetes-native CI orchestrator for this platform, running inside a dedicated CI-VKS cluster that is kept separate from the Runtime-VKS cluster used for application delivery. Tekton is a Cloud Native Computing Foundation (CNCF) project that extends the Kubernetes API itself, so Pipelines, Tasks and their executions are native Kubernetes objects: stored in etcd, managed with `kubectl`, and governed by the same RBAC as every other resource on the cluster.

This document is scoped strictly to the CI/build track. A developer commit triggers a webhook, which the EventListener turns into a PipelineRun; each step of the Pipeline runs in its own isolated Pod, sharing source code through a Workspace backed by a PersistentVolumeClaim. Once the OCI image is built, dedicated Task Pods generate a Software Bill of Materials (SBOM) with Syft and cryptographically sign the image digest with Cosign, attaching the SBOM as a verified attestation before the artifact and its supply chain evidence are pushed to Harbor.

This revision extends the reference architecture with the operational path required to run the same CI stack in a disconnected production environment: a version-gated prerequisites check (Section 9), an air-gapped installation and Harbor-mirroring procedure that now also mirrors the Cosign and Syft tooling images (Section 11), and the validation, readiness, and troubleshooting artifacts needed to certify and operate the install, including signature and attestation verification (Sections 12–14).

### Tekton Architecture on VKS

Tekton is deployed as the Pipeline Orchestrator inside the dedicated CI-VKS cluster, separate from the Runtime-VKS cluster that runs production application workloads. This isolation limits the blast radius of build activity and allows the CI and runtime environments to scale independently.

[ Developer Commit ]
         |
         v
[ Tekton Pipeline Executed ] ———> ( Buildpacks / BuildKit )
         |
         v
[ OCI Image Pushed ] ———————————> [ Harbor Registry ] ———> ( Vulnerability Scan & Signing )
         |
         v
[ GitOps Repo Updated ]
         |
         v
[ ArgoCD Reconciles ] ——————————> [ VKS Application Workload Deployed ]
         |
         v
[ Istio GW / cert-manager / external-dns ] ---> ( L7 Secure Routing Exposed )



### Why Tekton

#### Why We Are Using Tekton in This Project

- **Kubernetes-native:** runs directly on the VKS cluster we already operate — no separate CI server, VM pool, or agent fleet to patch and maintain.
- **Fits the architecture:** the wider CI/CD design (Buildpacks/BuildKit → Syft/Cosign → Harbor → Argo CD → Istio Gateway) is built around CNCF, Kubernetes-first tooling, and Tekton is the CNCF standard for pipeline orchestration.
- **RBAC reuse:** because Pipelines and Tasks are just Kubernetes objects, existing namespace-level RBAC policies control who can create or trigger builds — no separate permission system.
- **Isolation and reproducibility:** every build step — including SBOM generation and signing — runs in its own Pod, so one team's build cannot leak state into another's, and a build behaves the same way every time it runs.
- **Elastic scaling:** build load is scheduled and scaled by the same Kubernetes scheduler used for everything else on the cluster — no manual capacity planning for a separate CI farm.

### Custom Resource Definitions (CRDs)

A Custom Resource Definition (CRD) extends the standard Kubernetes API so the cluster understands new object types beyond the built-ins (Pod, Deployment, Service, etc.). Once a CRD is installed, Kubernetes treats the new object exactly like a native one — stored in etcd, managed through `kubectl`, and governed by the same RBAC rules.

Tekton defines its core concepts entirely as CRDs:

- **Pipeline** — the CRD describing an ordered set of Tasks.
- **Task** — the CRD describing one unit of build work (a set of Steps run in one Pod).
- **PipelineRun / TaskRun** — the CRDs representing one actual execution of a Pipeline or Task.
- **EventListener / TriggerBinding / TriggerTemplate** — the CRDs (from Tekton Triggers) that turn a webhook event into a new PipelineRun.

#### Why This Matters

- **No external dependency:** Tekton needs no separate database or control plane — it reuses the Kubernetes control plane and etcd that already exist.
- **Standard tooling:** pipelines are managed with the same `kubectl` commands, GitOps flows, and RBAC policies used for every other Kubernetes resource.
- **Declarative and versionable:** Pipeline/Task definitions are plain YAML, code-reviewed and stored in Git like any other manifest.

### Sample Infrastructure Manifest (release.yaml)

This is the structural deployment manifest that installs the Tekton control plane — the dedicated namespace, the controller's ServiceAccount, and the CRDs the engine needs to operate safely on VKS. In practice this file is applied from the official Tekton release URL (or, in disconnected environments, from the internal mirror — see the Air-Gapped section); the excerpt below shows the key object types it contains.

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
```
kubectl apply --filename \
  https://storage.googleapis.com/tekton-releases/pipeline/latest/release.yaml
kubectl get pods -n tekton-pipelines
```

### Sample Pipeline Workflow (pipeline.yaml)

This declarative Pipeline standardizes the code-to-artifact workflow. It clones the source, then attempts a Dockerfile-less build via Buildpacks (falling back to BuildKit only when a Dockerfile is explicitly present), generates an SBOM for the resulting image with Syft, cryptographically signs the image and attaches the SBOM as a verified attestation with Cosign, and only then hands the fully-evidenced OCI image off toward Harbor.

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
  - name: generate-sbom
    taskRef:
      name: syft-generate
    runAfter:
    - build-and-push-artifact
    workspaces:
    - name: source
      workspace: shared-workspace
    params:
    - name: image-reference
      value: $(params.image-reference)
    - name: output-file
      value: sbom-cyclonedx.json
  - name: sign-and-attest
    taskRef:
      name: cosign-sign-attest
    runAfter:
    - generate-sbom
    workspaces:
    - name: source
      workspace: shared-workspace
    params:
    - name: image-reference
      value: $(params.image-reference)
    - name: sbom-path
      value: $(workspaces.source.path)/sbom-cyclonedx.json
```

#### Pipeline Workflow Parameters Explained

| Field | Rationale & Function |
|---|---|
| `params` | Injects variables at runtime (e.g. the Git repo URL, the destination image tag in Harbor) without hardcoding values into the Pipeline definition. |
| `workspaces` | Binds a PVC-backed shared volume to the Pipeline so the git-clone Task can write source code to disk that the buildpacks, syft, and cosign Tasks then read. |
| `taskRef` | References a prebuilt, standardized Task (e.g. from the Tekton Catalog, or the internal `syft-generate` / `cosign-sign-attest` Tasks) instead of redefining build or signing logic from scratch, cutting developer overhead. |
| `runAfter` | Enforces execution order — guarantees the source code is fully cloned before the artifact builder Task starts, the image is fully built and pushed before the SBOM is generated, and the SBOM exists before Cosign signs the image and attaches it as an attestation. |
| `tasks[].name` | A unique label for that step within the Pipeline; referenced by other steps' `runAfter` and by logs/dashboards. |
| `workspaces` (per task) | Maps the Pipeline-level `shared-workspace` to the specific workspace name each Task expects internally (e.g. `output` for git-clone, `source` for buildpacks/syft/cosign). |
| `output-file` (param) | Tells the `syft-generate` Task the filename to write the generated CycloneDX SBOM to, inside the shared workspace, so it can be located by the next Task. |
| `sbom-path` (param) | Passes the exact on-disk location of the generated SBOM — `$(workspaces.source.path)/sbom-cyclonedx.json` — from `generate-sbom` into `sign-and-attest`, so Cosign knows precisely which file to attach as the attestation. |

#### Starting a Run Manually (Local Test)

```
tkn pipeline start vks-modern-app-pipeline \
  -w name=shared-workspace,claimName=my-pvc \
  -p repo-url=https://github.com/org/sample-app.git \
  -p image-reference=harbor.local/team/sample-app:test
tkn pipelinerun logs -f
```

### Prerequisites and Version Gate

Before any installation path (Internet-Connected or Air-Gapped) is started, the operator workstation and the target CI-VKS cluster must satisfy the version gate below. Pinning versions up front is what makes the air-gapped mirror reproducible — the mirror workstation and the cluster must always be built against the same tag, including the Cosign and Syft tooling used for supply chain security.

#### Required CLI Tooling

| Tool | Purpose | Minimum Version |
|---|---|---|
| `kubectl` | Applies manifests and inspects cluster state on the CI-VKS cluster | Matches cluster minor version (±1) |
| `tkn` | Tekton CLI — starts/inspects PipelineRuns, reads logs | v0.41.0 or later |
| `skopeo` | Copies and mirrors OCI images between registries without a full Docker daemon; required for the air-gapped path | v1.14 or later |
| `cosign` | Generates local key pairs for testing, and signs/verifies image signatures and attestations; required to validate the sign-and-attest Task output before it is trusted in production | v2.2 or later |
| `syft` | Generates CycloneDX/SPDX SBOMs locally so a developer can validate SBOM content and structure before it is generated in-pipeline by the generate-sbom Task | v1.0 or later |

#### Version-Pinning Environment Variables

Export these on the mirror workstation and reference them in place of `latest` anywhere a release manifest or image tag is used:

```
export TEKTON_PIPELINES_VERSION="v0.62.0"
export TEKTON_TRIGGERS_VERSION="v0.29.0"
export TEKTON_DASHBOARD_VERSION="v0.51.0"
export TEKTON_OPERATOR_VERSION="v0.75.0"
export TKN_CLI_VERSION="v0.41.0"
export COSIGN_VERSION="v2.2.4"
export SYFT_VERSION="v1.0.1"
export HARBOR_REGISTRY_HOST="harbor.internal.example.com"
```

#### Kubernetes Version Gate

| Requirement | Value |
|---|---|
| Minimum Kubernetes / VKS version | v1.28 |
| Recommended Kubernetes / VKS version | v1.29 or later |
| API groups required | `apiextensions.k8s.io/v1`, `admissionregistration.k8s.io/v1` |
| Pre-flight check | `kubectl version --short && kubectl api-versions | grep apiextensions.k8s.io/v1` |

> **ⓘ NOTE:** If the pre-flight check reports a cluster below v1.28, stop and remediate the cluster before proceeding — Tekton's webhook and CRD conversion behavior on older API groups is not supported by this document.

### Official Release Manifests, Commands & References (Internet-Connected)

All commands below are copied directly from the official Tekton project documentation (tekton.dev) and the tektoncd GitHub organization. These are the exact manifests to apply for a clean install where the cluster has outbound internet access. For a disconnected/air-gapped cluster, use the Air-Gapped section instead.

#### Tekton Pipelines (Core) — Required

*Current official CDN (tekton.dev points here as of 2026):*
```
kubectl apply --filename \
  https://infra.tekton.dev/tekton-releases/pipeline/latest/release.yaml
kubectl get pods --namespace tekton-pipelines --watch
```

*Legacy mirror (still valid, used in most existing docs/tutorials):*
```
kubectl apply --filename \
  https://storage.googleapis.com/tekton-releases/pipeline/latest/release.yaml
```

*Install a specific version instead of latest:*
```
kubectl apply --filename \
  https://infra.tekton.dev/tekton-releases/pipeline/previous/v1.15.1/release.yaml
```

*Untagged variant (only if the container runtime doesn't support `image:tag@digest`, e.g. older CRI-O/OpenShift):*
```
kubectl apply --filename \
  https://infra.tekton.dev/tekton-releases/pipeline/latest/release.notags.yaml
```

#### Tekton Triggers — Required only for webhook-based auto-trigger

```
kubectl apply --filename \
  https://storage.googleapis.com/tekton-releases/triggers/latest/release.yaml
kubectl apply --filename \
  https://storage.googleapis.com/tekton-releases/triggers/latest/interceptors.yaml
kubectl get pods --namespace tekton-pipelines --watch
```

#### Tekton Dashboard — Optional (visual PipelineRun monitoring)

*Read-only mode (default, recommended for shared/production clusters):*
```
kubectl apply --filename \
  https://infra.tekton.dev/tekton-releases/dashboard/latest/release.yaml
```

*Read/write mode (lets you trigger runs from the UI — fine for local testing):*
```
kubectl apply --filename \
  https://infra.tekton.dev/tekton-releases/dashboard/latest/release-full.yaml
```

*Access locally via port-forward:*
```
kubectl --namespace tekton-pipelines port-forward \
  svc/tekton-dashboard 9097:9097
# then open http://localhost:9097
```

#### Tekton CLI (tkn)

```
# macOS (Homebrew)
brew install tektoncd-cli

# Linux (x86_64)
curl -LO https://github.com/tektoncd/cli/releases/download/\
v0.41.0/tkn_0.41.0_Linux_x86_64.tar.gz
tar xvzf tkn_0.41.0_Linux_x86_64.tar.gz -C /usr/local/bin tkn
tkn version
```

#### Verifying the Installation

```
kubectl get pods -n tekton-pipelines
kubectl get crd | grep tekton.dev
```

#### Uninstalling (rollback / cleanup)

```
kubectl delete --filename \
  https://infra.tekton.dev/tekton-releases/pipeline/latest/release.yaml
kubectl delete --filename \
  https://storage.googleapis.com/tekton-releases/triggers/latest/release.yaml
```

#### Official References

| Resource | Official URL |
|---|---|
| Tekton Pipelines — Install docs | tekton.dev/docs/pipelines/install |
| Tekton Triggers — Install docs | tekton.dev/docs/triggers/install |
| Tekton Dashboard — Install docs | tekton.dev/docs/dashboard/install |
| Tekton Getting Started (Tasks) | tekton.dev/docs/getting-started/tasks |
| Tekton Catalog / Hub (reusable Tasks: git-clone, buildpacks) | hub.tekton.dev |
| Tekton Pipelines source & releases | github.com/tektoncd/pipeline |
| Tekton Triggers source & releases | github.com/tektoncd/triggers |
| Tekton Dashboard source & releases | github.com/tektoncd/dashboard |
| Tekton CLI (tkn) releases | github.com/tektoncd/cli/releases |
| Tekton Operator (managed install/upgrade) | github.com/tektoncd/operator |
| Sigstore Cosign — documentation & releases | docs.sigstore.dev/cosign · github.com/sigstore/cosign |
| Anchore Syft — documentation & releases | github.com/anchore/syft |
| CNCF project page | cncf.io/projects/tekton |



### Air-Gapped / Disconnected Setup

This section documents the offline installation path for CI-VKS clusters with no outbound internet access. It assumes the version gate and environment variables from the Prerequisites section — including `COSIGN_VERSION` and `SYFT_VERSION` — are already exported on the mirror workstation.

#### Disconnected Topology Overview

> **ⓘ NOTE — Flow (one-way):** [Connected Zone: tekton.dev / GHCR / Docker Hub / sigstore] → `skopeo copy` on Mirror Workstation → Local Manifest + Image Cache → (physical/secure transfer) → [Disconnected Zone: Internal Harbor Registry → Tekton Operator → CI-VKS Cluster]. The mirror workstation is the only component with outbound internet access.

#### Step 1 — Prepare the Mirror Workstation

On a workstation that has temporary internet access, create a local staging area and pull the pinned manifests:

```
mkdir -p ~/tekton-mirror/{manifests,images}
cd ~/tekton-mirror

curl -Lo manifests/pipeline-${TEKTON_PIPELINES_VERSION}.yaml \
  https://infra.tekton.dev/tekton-releases/pipeline/previous/${TEKTON_PIPELINES_VERSION}/release.yaml

curl -Lo manifests/triggers-${TEKTON_TRIGGERS_VERSION}.yaml \
  https://storage.googleapis.com/tekton-releases/triggers/previous/${TEKTON_TRIGGERS_VERSION}/release.yaml

curl -Lo manifests/operator-${TEKTON_OPERATOR_VERSION}.yaml \
  https://storage.googleapis.com/tekton-releases/operator/previous/${TEKTON_OPERATOR_VERSION}/release.yaml
```

#### Step 2 — Mirror Images to Internal Harbor

Use `skopeo copy` to move each Tekton component image — and both supply chain security tool images — from its public source registry directly into the internal Harbor project, preserving the pinned tag:

```
skopeo copy \
  docker://gcr.io/tekton-releases/github.com/tektoncd/pipeline/cmd/controller:${TEKTON_PIPELINES_VERSION} \
  docker://${HARBOR_REGISTRY_HOST}/tekton-mirror/pipeline-controller:${TEKTON_PIPELINES_VERSION}

skopeo copy \
  docker://gcr.io/tekton-releases/github.com/tektoncd/pipeline/cmd/webhook:${TEKTON_PIPELINES_VERSION} \
  docker://${HARBOR_REGISTRY_HOST}/tekton-mirror/pipeline-webhook:${TEKTON_PIPELINES_VERSION}

skopeo copy \
  docker://gcr.io/tekton-releases/github.com/tektoncd/triggers/cmd/controller:${TEKTON_TRIGGERS_VERSION} \
  docker://${HARBOR_REGISTRY_HOST}/tekton-mirror/triggers-controller:${TEKTON_TRIGGERS_VERSION}

skopeo copy \
  docker://gcr.io/tekton-releases/github.com/tektoncd/operator/cmd/kubernetes/operator:${TEKTON_OPERATOR_VERSION} \
  docker://${HARBOR_REGISTRY_HOST}/tekton-mirror/operator:${TEKTON_OPERATOR_VERSION}

# --- Supply chain security tooling (Syft + Cosign) ---
skopeo copy \
  docker://bitnami/cosign:${COSIGN_VERSION} \
  docker://${HARBOR_REGISTRY_HOST}/tekton-mirror/cosign:${COSIGN_VERSION}

skopeo copy \
  docker://anchore/syft:${SYFT_VERSION} \
  docker://${HARBOR_REGISTRY_HOST}/tekton-mirror/syft:${SYFT_VERSION}
```


#### Step 3 — Install the Tekton Operator Offline

From inside the disconnected zone, apply the staged Operator manifest:

```
kubectl apply -f manifests/operator-${TEKTON_OPERATOR_VERSION}.yaml
kubectl get pods -n tekton-operator --watch
```

#### Step 4 — Redirect the Operator to Internal Harbor

Edit the `tekton-operator` Deployment to inject `TEKTON_REGISTRY_OVERRIDE`, so every component the Operator subsequently reconciles — including the syft and cosign Tasks — pulls from the internal Harbor mirror:

```
kubectl edit deployment tekton-operator -n tekton-operator
```

Add the environment variable to the operator container spec:

```yaml
spec:
  template:
    spec:
      containers:
      - name: tekton-operator-lifecycle
        env:
        - name: TEKTON_REGISTRY_OVERRIDE
          value: "harbor.internal.example.com/tekton-mirror"
```

Equivalent one-line patch for scripted/GitOps-managed rollouts:

```
kubectl set env deployment/tekton-operator -n tekton-operator \
  TEKTON_REGISTRY_OVERRIDE=${HARBOR_REGISTRY_HOST}/tekton-mirror
```

Restart the Operator so the override takes effect:

```
kubectl rollout restart deployment/tekton-operator -n tekton-operator
kubectl rollout status deployment/tekton-operator -n tekton-operator
```

#### Step 5 — Point Pipelines at the Mirror

Update the TektonConfig custom resource (or the individual TaskRef images used in the sample Pipeline) so Buildpacks/BuildKit, git-clone, syft-generate, and cosign-sign-attest Task images also resolve against `${HARBOR_REGISTRY_HOST}/tekton-mirror` rather than the public Tekton Catalog or public tool registries. This keeps every Pod scheduled by the CI-VKS cluster fully inside the disconnected network boundary.

#### Step 6 — Generate the Cosign Key Pair In-Cluster

Generate the Cosign signing key pair natively and store it as a Kubernetes Secret, so the sign-and-attest Task can sign images without any key material ever leaving the CI-VKS cluster:

```
cosign generate-key-pair k8s://tekton-pipelines/cosign-keys

# Verify the Secret was created in the tekton-pipelines namespace
kubectl get secret cosign-keys -n tekton-pipelines
```

> **ⓘ NOTE:** The `generate-key-pair` command with a `k8s://` destination writes `cosign.key` (encrypted with a password you supply) and `cosign.pub` directly into a new Kubernetes Secret — the private key is never written to local disk. Store the key password itself in a separate Kubernetes Secret (see Production Readiness Checklist) and reference both from the sign-and-attest Task; do not commit either to Git.


### Summary

Tekton gives this project a Kubernetes-native, CRD-based CI engine that removes the need for external build infrastructure, reuses existing RBAC boundaries, and guarantees reproducible, isolated builds per step. The Pipeline shown in the Sample Pipeline Workflow section (clone → build via Buildpacks/BuildKit → generate SBOM with Syft → sign and attest with Cosign → push) is the minimum working CI loop that can be validated locally before wiring in Harbor governance, GitOps updates, and Argo CD delivery, which are documented in the companion Argo CD implementation guide.

This revision closes the gap between that reference architecture and a disconnected production rollout with software supply chain security natively enforced end to end: the Prerequisites section gates the install on the right tooling and pinned versions, including Cosign and Syft; the Air-Gapped section gives the mirror-workstation-to-Harbor path — now covering the Syft and Cosign tool images and in-cluster key generation — for environments with no outbound internet access; and the Validation Matrix, Production Readiness Checklist, and Troubleshooting sections give the validation, sign-off, and troubleshooting artifacts, including signature and attestation verification, needed to certify the CI stack as production-ready in either mode.

*
