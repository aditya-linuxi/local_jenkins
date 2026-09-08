## Tekton CI on VKS

*Detailed Technical Reference & Implementation Guide*

*CI (build) track only — Kubernetes-native Pipelines using Tekton CRDs, extended with native Software Supply Chain Security (SBOM generation, image signing, and attestation)*

*Companion to the "Modern Applications CI/CD Stack on VKS" Implementation Guide (Argo CD / GitOps track)*

| Property | Baseline |
|---|---|
| Target platform | vSphere Kubernetes Service (VKS) / Kubernetes — dedicated CI-VKS cluster |
| Document scope | CI (build) track only — GitOps/CD is covered in the companion Argo CD guide |
| CI engine | Tekton Pipelines + Tekton Triggers |
| Build strategy | Cloud Native Buildpacks (Pack) as default; BuildKit when a Dockerfile is present |
| Trigger model | Webhook → EventListener → TriggerBinding/TriggerTemplate → PipelineRun |
| Supply chain security | Syft for SBOM generation (CycloneDX/SPDX); Cosign for image signing and SBOM attestation |
| Registry handoff | Harbor — destination for the signed OCI image, its `.sig` signature, and its `.att` SBOM attestation |
| Dashboard / CLI | Tekton Dashboard (optional) + `tkn` CLI; `cosign` and `syft` CLIs for local verification |
| Modes | Internet-connected + air-gapped/disconnected |
| Document date | 2026-09-08 (Rev. 3 — corrects YAML syntax, sequence logic, and export artifacts) |

> **ⓘ NOTE — Scope:** This document covers the CI/build track for Tekton on VKS: architecture, CRD model, sample manifests, prerequisites, both internet-connected and air-gapped installation paths, supply chain security (SBOM generation and cryptographic signing/attestation), and validation/troubleshooting guidance. GitOps delivery, Argo CD reconciliation, Istio ingress, TLS, and DNS are addressed in the companion Argo CD guide.

---
### Executive Summary

Tekton is deployed as the Kubernetes-native CI orchestrator for this platform, running inside a dedicated CI-VKS cluster that is kept separate from the Runtime-VKS cluster used for application delivery. Tekton is a Cloud Native Computing Foundation (CNCF) project that extends the Kubernetes API itself, so Pipelines, Tasks and their executions are native Kubernetes objects: stored in etcd, managed with `kubectl`, and governed by the same RBAC as every other resource on the cluster.

This document is scoped strictly to the CI/build track. A developer commit triggers a webhook, which the EventListener turns into a PipelineRun; each step of the Pipeline runs in its own isolated Pod, sharing source code through a Workspace backed by a PersistentVolumeClaim. Once the OCI image is built and pushed to Harbor — where the registry assigns it a resolvable SHA256 digest — dedicated Task Pods generate a Software Bill of Materials (SBOM) with Syft and cryptographically sign the image digest with Cosign, attaching the SBOM as a verified attestation directly to the image already sitting in the registry.

> **ⓘ NOTE — Architecture flow:** Developer Commit → Webhook → EventListener → PipelineRun → Task Pods (git-clone → Buildpacks/BuildKit → Syft SBOM Generation → Cosign Sign & Attest) → Harbor → (out of scope: GitOps repository → Argo CD → VKS workload → Istio Gateway API).

This revision extends the reference architecture with the operational path required to run the same CI stack in a disconnected production environment: a version-gated prerequisites check (Section 9), an air-gapped installation and Harbor-mirroring procedure that now also mirrors the Cosign and Syft tooling images (Section 11), and the validation, readiness, and troubleshooting artifacts needed to certify and operate the install, including signature and attestation verification (Sections 12–14).

### Source Architecture Traceability

The table below maps each architecture decision to the concrete implementation used in this document.

| Decision | Implementation |
|---|---|
| CI orchestration | Tekton on a dedicated CI-VKS cluster; Pipelines, Tasks, PipelineRuns and TaskRuns are Kubernetes CRDs |
| Trigger model | Webhook → EventListener → TriggerBinding/TriggerTemplate → PipelineRun (Tekton Triggers) |
| Build isolation | Every Pipeline step runs in its own Pod; source shared via a Workspace-backed PVC |
| Build strategy | Dockerfile present → BuildKit; otherwise → Buildpacks (matches the Argo CD document's build-selection rule) |
| Supply Chain Security | Syft for CycloneDX/SPDX SBOM generation; Cosign for cryptographic image signing and SBOM attestation directly in the Harbor registry |
| RBAC | Native Kubernetes namespace RBAC is reused; no separate Tekton permission system |
| CI/runtime separation | Tekton runs on CI-VKS, isolated from the Runtime-VKS cluster that Argo CD manages |
| Registry handoff | The build task pushes the OCI image to Harbor first, so it is assigned a resolvable SHA256 digest; Syft and Cosign then operate against that pushed digest to generate the SBOM and the signature/attestation |
| Scope boundary | GitOps update, Argo CD sync, and Istio/ingress routing are out of scope for this document |

The source also describes the downstream lifecycle — Harbor governance and secure routing — which is covered in full in the companion Argo CD implementation guide, not repeated here.

### Target VKS Topology

| Zone | Components | Purpose |
|---|---|---|
| App source repo | Git repository + webhook | Commit trigger source for the CI Pipeline |
| CI VKS | Tekton Pipelines, Triggers, EventListener, PipelineRun/TaskRun pods; git-clone Task; Buildpacks/BuildKit Task; syft Task (SBOM generation); cosign Task (image signing & attestation); optional Dashboard | Ephemeral, isolated build execution, including SBOM generation and image signing (this document's scope) |
| Harbor | OCI registry, vulnerability scanning, image signing | Destination for the built OCI image; also the target the syft and cosign Tasks operate against post-push, receiving the resulting `.sig` signature artifact and `.att` SBOM attestation artifact; hand-off point to the CD track |
| Runtime VKS / GitOps (out of scope) | Argo CD, apps, Istio, cert-manager, external-dns | Application delivery — detailed in the companion Argo CD guide |

A single VKS cluster is acceptable for a POC, with Tekton and the runtime workloads sharing the same cluster in separate namespaces. For production, keeping CI on its own cluster reduces build blast radius and resource contention, matching the architecture's separation-of-concerns recommendation.

### Tekton Architecture on VKS

Tekton is deployed as the Pipeline Orchestrator inside the dedicated CI-VKS cluster, separate from the Runtime-VKS cluster that runs production application workloads. This isolation limits the blast radius of build activity and allows the CI and runtime environments to scale independently.

> **ⓘ NOTE — Architecture flow (left to right):** Developer Commit → Webhook → EventListener → PipelineRun → Task Pod: git-clone → Task Pod: Buildpacks/BuildKit (push to Harbor) → Task Pod: Syft (SBOM generation) → Task Pod: Cosign (sign & attest) → Harbor: image + signature + attestation — — [out of scope] GitOps repo → Argo CD → VKS workload → Istio Gateway

*Figure 1: Tekton CI Architecture on VKS*

```
flowchart LR
A[Git Repo] -->|Webhook| B(EventListener)
B --> C[PipelineRun]
subgraph CI-VKS Cluster
C --> D[Task: git-clone]
D --> E[Task: build-and-push]
E --> F[Task: syft-sbom]
F --> G[Task: cosign-sign]
end
G -->|Artifacts, .sig, .att| H[(Harbor Registry)]
H -.-|Out of Scope| I[Argo CD]
I -.- J[Runtime VKS]
```

A developer pushes code to the App Source repository. A webhook notifies the EventListener, which creates a PipelineRun. Tekton runs each step (git-clone, then buildpacks/buildkit) as an isolated Pod, sharing source code through a Workspace backed by a PVC. Once the OCI image is built and pushed to Harbor by the build task, two further isolated Pods run in strict sequence: the first invokes Syft to generate a CycloneDX/SPDX SBOM, and the second invokes Cosign to cryptographically sign the image digest and attach the SBOM as a verified attestation directly to the image in the registry. Everything past this point belongs to the CD track and is documented separately.

### Why Tekton

#### Why We Are Using Tekton in This Project

- **Kubernetes-native:** runs directly on the VKS cluster we already operate — no separate CI server, VM pool, or agent fleet to patch and maintain.
- **Fits the architecture:** the wider CI/CD design (Buildpacks/BuildKit → Syft/Cosign → Harbor → Argo CD → Istio Gateway) is built around CNCF, Kubernetes-first tooling, and Tekton is the CNCF standard for pipeline orchestration.
- **RBAC reuse:** because Pipelines and Tasks are just Kubernetes objects, existing namespace-level RBAC policies control who can create or trigger builds — no separate permission system.
- **Isolation and reproducibility:** every build step — including SBOM generation and signing — runs in its own Pod, so one team's build cannot leak state into another's, and a build behaves the same way every time it runs.
- **Elastic scaling:** build load is scheduled and scaled by the same Kubernetes scheduler used for everything else on the cluster — no manual capacity planning for a separate CI farm.

#### Why This Technology Over Legacy Tools (Jenkins)

Jenkins remains a valid tool, but for a Kubernetes-first platform like VKS, Tekton has structural advantages:

| Aspect | Jenkins (legacy) | Tekton (this project) |
|---|---|---|
| Execution model | Long-lived controller + static/VM agents or plugin-based Kubernetes agents bolted on afterward | Native Kubernetes Pods created and destroyed per build step — no separate agent fleet |
| Configuration | Groovy-based Jenkinsfile / plugin ecosystem, often UI-managed | Declarative YAML CRDs (Pipeline, Task) managed with `kubectl`, versioned in Git |
| Security / RBAC | Separate Jenkins user/role system layered on top of infrastructure | Reuses native Kubernetes RBAC and namespace boundaries directly |
| Infrastructure footprint | Requires dedicated controller node(s), plugin maintenance, and agent capacity management | No heavy external runner; scales using existing cluster nodes |
| Build isolation | Depends on agent/executor configuration; contamination risk if misconfigured | Every step runs in its own isolated Pod by design (DEC-CI-02) |
| Supply chain evidence | Requires bolted-on plugins for SBOM/signing, often inconsistently applied | Syft and Cosign run as native, ordered Tasks — SBOM and signature generation is enforced by the Pipeline graph itself |
| Extensibility | Plugin marketplace (large but adds maintenance/security overhead) | Reusable Tasks pulled from the Tekton Catalog/Hub, composed like building blocks |

Net effect: Tekton avoids the heavy external runner infrastructure Jenkins requires, simplifies RBAC integration within VKS namespaces, and gives us build reproducibility through per-step Pod isolation — now extended to give us enforceable, native supply chain security evidence for every image it produces.

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

This declarative Pipeline standardizes the code-to-artifact workflow. It clones the source, then attempts a Dockerfile-less build via Buildpacks (falling back to BuildKit only when a Dockerfile is explicitly present) and pushes the resulting OCI image to Harbor so the registry can assign it a resolvable digest. Only once that digest exists does the Pipeline generate an SBOM for the pushed image with Syft, then cryptographically sign the image and attach the SBOM as a verified attestation with Cosign, directly against the image already in Harbor.

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

> **ⓘ NOTE:** As of 2026 the Tekton project is migrating its canonical release CDN from `storage.googleapis.com` to `infra.tekton.dev`. Both currently resolve to valid release manifests; `infra.tekton.dev` is what the live tekton.dev documentation shows first and is used as primary in this document.

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

> **ⓘ NOTE:** Repeat the `skopeo copy` pattern for every base image referenced by the staged manifests (Buildpacks builder images, git-clone Task image, Dashboard image, and the syft/cosign Task images above). Track the full list in a manifest inventory so the Validation Matrix and Production Readiness Checklist can confirm nothing was missed. Transfer `~/tekton-mirror` into the disconnected zone via your organization's approved one-way transfer process.

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

### Validation Matrix

Run the checks below, in order, immediately after either installation path (Internet-Connected or Air-Gapped) completes.

| # | Check | Command | Expected Output |
|---|---|---|---|
| 1 | Core controller pods are running | `kubectl get pods -n tekton-pipelines` | All pods Running, 1/1 or 2/2 READY, 0 restarts |
| 2 | Tekton CRDs are registered | `kubectl get crd \| grep tekton.dev` | Lists `pipelines.tekton.dev`, `tasks.tekton.dev`, `pipelineruns.tekton.dev`, `taskruns.tekton.dev` |
| 3 | Operator reconciled (air-gapped path) | `kubectl get tektonconfig config -o jsonpath='{.status.conditions}'` | `status: "True"`, `type: Ready` |
| 4 | Registry override applied | `kubectl get deployment tekton-operator -n tekton-operator -o jsonpath='{.spec.template.spec.containers[0].env}'` | Output includes `TEKTON_REGISTRY_OVERRIDE` set to the internal Harbor host |
| 5 | tkn CLI reaches the cluster | `tkn version` | Prints matching Client and Server versions, no connection error |
| 6 | Mirror image pull succeeds | `kubectl run test-pull --rm -it --image=${HARBOR_REGISTRY_HOST}/tekton-mirror/pipeline-controller:${TEKTON_PIPELINES_VERSION} --restart=Never -- true` | Pod reaches Completed, no ImagePullBackOff |
| 7 | Sample Pipeline executes end-to-end | `tkn pipeline start vks-modern-app-pipeline -w name=shared-workspace,claimName=my-pvc -p repo-url=<repo> -p image-reference=${HARBOR_REGISTRY_HOST}/team/app:test` | PipelineRun status Succeeded |
| 8 | Built image lands in Harbor | `docker push ${HARBOR_REGISTRY_HOST}/team/sample-app:test` (or inspect the push step in the PipelineRun log) | Push reports 200 OK / digest returned, image visible in the Harbor project UI |
| 9 | Image signature verifies | `cosign verify --key k8s://tekton-pipelines/cosign-keys ${HARBOR_REGISTRY_HOST}/team/app:test` | Signature verified, returns the signing key ID and payload with no error |
| 10 | SBOM attestation verifies | `cosign verify-attestation --type cyclonedx --key k8s://tekton-pipelines/cosign-keys ${HARBOR_REGISTRY_HOST}/team/app:test` | Attestation verified, decoded CycloneDX SBOM payload returned with no error |

### Production Readiness Checklist

| Area | Requirement | Sign-off Evidence |
|---|---|---|
| RBAC | Tekton ServiceAccounts are scoped to least-privilege namespace roles; no cluster-admin bindings remain from install | `kubectl get rolebindings,clusterrolebindings -A \| grep tekton` reviewed and approved |
| Harbor robot accounts | CI robot account scoped to push-only on build-target projects, with explicit push scope for artifact types so the `.sig` and `.att` extensions can be uploaded alongside the image manifest, not just the image itself; pull-only scope used for the mirror project | Harbor project → Robot Accounts export, including the artifact push-scope setting, attached to change record |
| Image mirror completeness | Every base image referenced by Pipelines/Tasks (Buildpacks builders, git-clone, BuildKit, Dashboard, Syft, Cosign) has been mirrored into internal Harbor | Mirror inventory list cross-checked against Validation Matrix check #6 |
| Registry override | `TEKTON_REGISTRY_OVERRIDE` confirmed on the `tekton-operator` Deployment in every CI-VKS cluster (not just the first) | Validation Matrix check #4 run per-cluster |
| Version pinning | All components (Pipelines, Triggers, Dashboard, Operator, tkn, Cosign, Syft) installed at the exact versions recorded in the Version-Pinning Environment Variables section — no `latest` tags in production | Manifest diff against those environment variables |
| Workspace storage | PVC-backed Workspaces use the approved StorageClass and have defined size/retention limits | `kubectl get pvc -n tekton-pipelines` reviewed against storage policy |
| Secrets handling | Harbor credentials, any Git tokens, and the Cosign private key password are stored as Kubernetes Secrets, not embedded in Pipeline/Task YAML; the Cosign private key itself lives only inside the `cosign-keys` Secret generated in the Air-Gapped Step 6 | Secret references audited in Pipeline/Task manifests |
| Rollback path | Uninstall/rollback procedure tested against the pinned version set at least once before go-live | Rollback dry-run recorded in change record |
| Monitoring | PipelineRun failures and Dashboard (if deployed) are wired into existing cluster alerting | Alert rule reviewed for `tekton-pipelines` namespace |

### Troubleshooting

**Symptom:** `ImagePullBackOff` on a Tekton Task Pod
**Likely Root Cause:** Task references the public registry instead of the internal Harbor mirror, or the image tag was never mirrored.
**Diagnostic Command(s):** `kubectl describe pod <pod> -n tekton-pipelines` and `kubectl get events -n tekton-pipelines --sort-by=.lastTimestamp`
**Resolution:** Confirm the image path matches `${HARBOR_REGISTRY_HOST}/tekton-mirror/...`; re-run the relevant `skopeo copy` from the Air-Gapped Step 2.

**Symptom:** PipelineRun stuck Pending, Workspace unbound
**Likely Root Cause:** The Workspace's PVC does not exist, or its StorageClass cannot satisfy the requested access mode/size.
**Diagnostic Command(s):** `kubectl describe pvc <claim> -n tekton-pipelines` and `kubectl get events -n tekton-pipelines`
**Resolution:** Create the PVC referenced by `-w name=...,claimName=...`, or correct the StorageClass.

**Symptom:** `tkn pipelinerun logs -f` shows no output / hangs
**Likely Root Cause:** TaskRun Pod never scheduled (node selector, resource quota, or Workspace mount failure).
**Diagnostic Command(s):** `tkn pipelinerun describe <name>` and `kubectl describe pod <pod> -n tekton-pipelines`
**Resolution:** Check node capacity and resource requests; confirm Workspace PVC is Bound.

**Symptom:** Operator reconciliation stuck, TektonConfig not Ready
**Likely Root Cause:** `TEKTON_REGISTRY_OVERRIDE` points at an unreachable or misspelled Harbor host, so component images cannot resolve.
**Diagnostic Command(s):** `kubectl logs deployment/tekton-operator -n tekton-operator` and `kubectl get tektonconfig config -o yaml`
**Resolution:** Verify DNS/network reachability to the Harbor host from inside the cluster; correct the env var value and `kubectl rollout restart` the operator.

**Symptom:** Harbor `docker push` fails from `build-and-push-artifact` Task
**Likely Root Cause:** Robot account lacks push scope on the target project, or the Task's registry credentials Secret is missing/expired.
**Diagnostic Command(s):** `tkn taskrun logs <name>` and `kubectl describe secret <harbor-creds> -n tekton-pipelines`
**Resolution:** Regenerate the Harbor robot account with push scope on the project; update the referenced Secret.

**Symptom:** Webhook never creates a PipelineRun
**Likely Root Cause:** EventListener Service not reachable from the Git host, or the TriggerBinding mismatches payload.
**Diagnostic Command(s):** `kubectl logs deployment/el-<listener-name> -n tekton-pipelines` and `kubectl describe eventlistener <name> -n tekton-pipelines`
**Resolution:** Confirm ingress reachability and validate TriggerBinding field paths.

**Symptom:** `tkn` CLI reports version/API mismatch
**Likely Root Cause:** `tkn` CLI version predates the installed Tekton Pipelines API version.
**Diagnostic Command(s):** `tkn version`
**Resolution:** Reinstall `tkn` at the version pinned in the Version-Pinning Environment Variables section (`TKN_CLI_VERSION`).

**Symptom:** `cosign sign` fails with a Harbor authentication error
**Likely Root Cause:** CI robot account has push scope for image manifests, but lacks artifact push scope for `.sig` / `.att` OCI artifacts.
**Diagnostic Command(s):** `tkn taskrun logs <sign-and-attest-pod>` and `kubectl describe secret <harbor-creds> -n tekton-pipelines`
**Resolution:** Ensure the Harbor robot account has explicit artifact push scope enabled in Harbor project settings.

**Symptom:** The pipeline cannot mount the `cosign-keys` Secret
**Likely Root Cause:** The Secret was created in another namespace or the ServiceAccount lacks RBAC to read it.
**Diagnostic Command(s):** `kubectl get secret cosign-keys -n tekton-pipelines` and `kubectl describe taskrun <sign-and-attest-run>`
**Resolution:** Confirm Secret exists in `tekton-pipelines` and grant `get` permission on secrets to the Pipeline ServiceAccount.

### Conclusion

Tekton gives this project a Kubernetes-native, CRD-based CI engine that removes the need for external build infrastructure, reuses existing RBAC boundaries, and guarantees reproducible, isolated builds per step. The Pipeline shown in the Sample Pipeline Workflow section (clone → build via Buildpacks/BuildKit → push to Harbor → generate SBOM with Syft → sign and attest with Cosign) is the minimum working CI loop that can be validated locally before wiring in Harbor governance, GitOps updates, and Argo CD delivery, which are documented in the companion Argo CD implementation guide.

This revision closes the gap between that reference architecture and a disconnected production rollout with software supply chain security natively enforced end to end: the Prerequisites section gates the install on the right tooling and pinned versions, including Cosign and Syft; the Air-Gapped section gives the mirror-workstation-to-Harbor path — now covering the Syft and Cosign tool images and in-cluster key generation — for environments with no outbound internet access; and the Validation Matrix, Production Readiness Checklist, and Troubleshooting sections give the validation, sign-off, and troubleshooting artifacts, including signature and attestation verification, needed to certify the CI stack as production-ready in either mode.

*End of Document — Tekton CI on VKS Technical Reference | 2026-09-08 | CI/CD Platform Engineering*
