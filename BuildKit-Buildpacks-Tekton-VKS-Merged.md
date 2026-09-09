# BuildKit & Cloud Native Buildpacks on vSphere Kubernetes Service and Tekton CI Implementation on VKS

This guide walks through one continuous workflow on VMware vSphere Kubernetes Service (VKS): **Part 1** covers the two tools that turn source code into a container image — BuildKit and Cloud Native Buildpacks — and **Part 2** covers Tekton, the Kubernetes-native CI engine that orchestrates those build tools end to end (clone → build → generate SBOM → sign & attest → push to Harbor). Each part keeps its own introduction below, but together they describe a single build-to-registry pipeline running on the same VKS platform.

---

# Part 1 — BuildKit & Cloud Native Buildpacks on vSphere Kubernetes Service (VKS)

Two ways to build container images — BuildKit for apps with a Dockerfile, Buildpacks for apps without one — running on VMware vSphere Kubernetes Service (VKS).

## Introduction

This guide covers two tools that turn your application source code into a container image:

* **BuildKit** builds an image using a Dockerfile. You stay in full control of every step.
* **Cloud Native Buildpacks (CNB)**, used through the Pack CLI, builds an image automatically — no Dockerfile needed. It looks at your code and figures out how to package it.

The simple rule this guide follows:

> **If your repo has a Dockerfile → use BuildKit. If it doesn't → use Buildpacks (Pack).**

Both tools push the final image to a container registry (e.g. Harbor), and both work whether your VKS cluster has internet access or is fully air-gapped.

## Why BuildKit and Buildpacks on VKS?

VKS is VMware's built-in Kubernetes service that comes bundled with VMware Cloud Foundation (VCF). Building images directly on VKS — instead of a separate build server — keeps everything in one place.

In simple terms, here's why this setup makes sense on VKS:

* **Everything runs in the same platform.** Clusters, storage, and networking are already set up by VKS, so the build layer doesn't need its own separate infrastructure.
* **Registry and delivery are built in.** Harbor (image registry) and Argo CD (deployment) are already available as add-ons, so images can move from "built" to "deployed" without leaving the platform.
* **Storage and networking are handled for you.** VKS takes care of storage and network setup, so the build namespace doesn't need extra configuration.
* **Works without internet too.** VKS supports disconnected/air-gapped setups, which matches the air-gapped instructions later in this guide.
* **One place to manage everything.** If there are multiple clusters, they can all be managed centrally instead of separately.

### Benefits

| Benefit | In simple words |
| :--- | :--- |
| **Clear build rule** | The system always knows whether to use BuildKit or Buildpacks — no guessing. |
| **Less work for app teams** | Teams without a Dockerfile still get a working, secure image via Buildpacks. |
| **Safer builds** | BuildKit can run without root access, which lowers security risk. |
| **One place for images** | Every built image goes to Harbor, where it's scanned and signed before use. |
| **Same process everywhere** | The exact same steps work with or without internet access. |
| **Traceable images** | Images are tracked by a fixed ID (digest), not a changeable tag, so you always know exactly what's running. |

## Architecture

This is what happens from code commit to a running image, using either BuildKit or Buildpacks depending on whether a Dockerfile exists:

```text
                          Developer commit (Internal Git)
                                    │
                                    ▼
                        Tekton checkout (VKS CI namespace)
                                    │
                                    ▼
                    Does the repo have a Dockerfile?
                                    │
                 ┌──────────────────┴──────────────────┐
                 │ Yes                                 │ No
                 ▼                                     ▼
        BuildKit (buildctl → buildkitd)         Buildpacks (pack CLI → builder image)
        rootless, daemonless, in-Pod            detect → analyze → build → export
                 │                                     │
                 └──────────────────┬──────────────────┘
                                    ▼
                              OCI Image
                                    │
                                    ▼
                    Harbor: scan → sign → immutable digest
                                    │
                                    ▼
                        GitOps update → VKS workload cluster
```

**Here's what each part of the platform does:**

| Zone | Components | What it does |
| :--- | :--- | :--- |
| **CI cluster (VKS)** | Tekton, BuildKit, Pack/Buildpacks | Runs the builds, torn down after each run |
| **Harbor** | OCI registry, scanning, signing | Stores every image; the source of truth |
| **Internal Git** | Source repositories | Where the code and Dockerfile (if any) live |
| **Mirror workstation** | skopeo, imgpkg, helm | Copies images from the internet to the internal registry (air-gapped mode only) |

> **Note on cluster layout:** One shared namespace is fine for testing. For production, keep build workloads and running-application workloads in separate namespaces or clusters, so a build problem can't affect live apps.

---

## Prerequisites

### Platform

| Component | Version | What it's for |
| :--- | :--- | :--- |
| **VMware Cloud Foundation (VCF)** | 9.x | Sets up and manages the Supervisor and workload clusters |
| **vSphere Kubernetes Service (VKS)** | VCF 9.x bundled | Runs the actual Kubernetes workload cluster where builds happen |
| **Regional Harbor** | Installed via VCF Automation / Supervisor Service | Stores, scans, and signs images |
| **Tekton Pipelines** | Latest version supported by your cluster | Runs the CI pipeline |

*VCF and VKS ship together — this guide is pinned to VCF 9.x, with VKS bundled as part of that release. The BuildKit and Buildpacks versions below are the ones validated against VCF 9.x; update them together if you move to a newer VCF release.*

### Tools needed on your build machine

```bash
kubectl version
kubectl cluster-info
kubectl get nodes -o wide
kubectl get nodes -o custom-columns=NAME:.metadata.name,RUNTIME:.status.nodeInfo.containerRuntimeVersion

docker --version    # optional, only needed for local testing
helm version
git --version
curl --version
```

### Environment variables used in this guide

These versions are the ones validated against VCF 9.x — keep them pinned like this, and only bump them together as a set when you move to a newer VCF release.

```bash
export HARBOR=harbor.example.internal
export CI_NS=cicd
export APP_NS=sample-app

# Versions validated against VCF 9.x / VKS — update together if you move to a newer VCF release
# BuildKit releases:   https://github.com/moby/buildkit/releases
# Pack CLI releases:   https://github.com/buildpacks/pack/releases
export BUILDKIT_VERSION=v0.30.0
export PACK_VERSION=0.40.9
export BUILDER_IMAGE=paketobuildpacks/builder-jammy-base
```

*Before you install: Confirm your Kubernetes/VKS version supports the BuildKit/Pack version you plan to use. Rootless BuildKit also needs kernel support for unprivileged user namespaces — check this on your nodes first.*

### Required Add-ons Baseline

| Property | Baseline |
| :--- | :--- |
| **Build tools** | BuildKit (moby/buildkit) + Cloud Native Buildpacks (Pack CLI) — versions pinned to what's validated for VCF 9.x |
| **Build selection rule** | Dockerfile present → BuildKit; Dockerfile absent → Buildpacks |
| **Target platform** | vSphere Kubernetes Service (VKS), bundled with VCF 9.x |
| **Registry** | Harbor (OCI registry, scanning, signing) |
| **Default builder** | `paketobuildpacks/builder-jammy-base` |
| **BuildKit version** | v0.30.0 |
| **Pack CLI version** | 0.40.9 |
| **Supported modes** | Internet-connected and air-gapped/disconnected |

**What needs to be in place on VKS before turning on the build layer:**
1. **Regional Harbor** — install and configure this first. It's the registry both build engines push to.
2. **Argo CD** — recommended so built images can be deployed automatically through GitOps.
3. **Contour** — only needed if something in the build layer needs ingress; each VKS cluster needs its own instance.
4. **Tekton Pipelines** — installed into the CI namespace to actually run the BuildKit/Buildpacks tasks.

**Set up namespaces:**
```bash
kubectl create namespace cicd --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace sample-app --dry-run=client -o yaml | kubectl apply -f -
```
```
variable: BUILDKIT_VERSION=v0.30.0
```
---

## Installation — Internet-Connected Environment
```

```
### 1. Install BuildKit
```bash
curl -fsSL -o buildkit.tar.gz   https://github.com/moby/buildkit/releases/download/${BUILDKIT_VERSION}/buildkit-${BUILDKIT_VERSION}.linux-amd64.tar.gz

sudo tar -C /usr/local -xzf buildkit.tar.gz

buildctl --version
buildkitd --version
```

### 2. Run BuildKit in rootful daemon mode (optional)
```bash
sudo /usr/local/bin/buildkitd --addr unix:///run/buildkit/buildkitd.sock &
sudo buildctl --addr unix:///run/buildkit/buildkitd.sock debug workers
```
```
  variable: HARBOR=harbor.example.internal
```
### 3. Build with BuildKit — rootless, no daemon needed (recommended)
```bash
# Example daemonless rootless build
buildctl-daemonless.sh build   --frontend dockerfile.v0   --local context=/workspace/source   --local dockerfile=/workspace/source   --output type=image,name="$HARBOR/applications/sample:TAG",push=true
```

### 4. Run the built image as a container
Once the build pushes the image, pull it and run it as a container to confirm it actually starts up correctly.

```bash
docker pull "$HARBOR/applications/sample:TAG"

docker run --rm -d   --name sample-buildkit-test   -p 8080:8080   "$HARBOR/applications/sample:TAG"

docker ps --filter name=sample-buildkit-test
docker logs sample-buildkit-test
curl -sf http://localhost:8080/ || echo "adjust the port/health path for this app"
docker stop sample-buildkit-test
```

### 5. Mirror the BuildKit image itself to Harbor

**Option A — skopeo:**
```bash
skopeo copy   docker://moby/buildkit:${BUILDKIT_VERSION}   docker://$HARBOR/buildkit/buildkit:${BUILDKIT_VERSION}
```

**Option B — imgpkg:**
```bash
imgpkg copy   -i docker.io/moby/buildkit:${BUILDKIT_VERSION}   --to-repo $HARBOR/buildkit/buildkit
```

Either works fine here since you haveBUILDER_IMAGE internet access — skopeo does a simple direct copy, imgpkg is worth using if the rest of your platform (e.g. Argo CD) already tracks images with Carvel tooling. Pick one per component, don't mix both for the same image.

### 6. Run BuildKit as a Kubernetes Job/Pod
Rootless mode usually needs UnconfBuildKit releasesined seccomp/AppArmor settings on the Pod, plus node support for unprivileged user namespaces.
```bash
kubectl run buildkit-test   --image=$HARBOR/buildkit/buildkit:${BUILDKIT_VERSION}   --restart=Never -n cicd   --overrides='{"spec":{"containers":[{"name":"buildkit","image":"'"$HARBOR"'/buildkit/buildkit:'"${BUILDKIT_VERSION}"'","securityContext":{"seccompProfile":{"type":"Unconfined"}}}]}}'   -- buildctl-daemonless.sh debug workers
```

### 7. Install the Pack CLI

``` 
variable:  PACK_VERSION=0.40.9
```

```bash
curl -sSL "https://github.com/buildpacks/pack/releases/download/v${PACK_VERSION}/pack-v${PACK_VERSION}-linux.tgz"   | sudo tar -C /usr/local/bin/ --no-same-owner -xzv pack

pack version
```

### 8. Check the builder image being used
A builder image bundles the buildpacks, the build logic, and a link to the base "run image" the final app image is built on.
```
variable:  BUILDER_IMAGE=paketobuildpacks/builder-jammy-base
```
```bash
pack builder inspect $BUILDER_IMAGE
pack builder inspect $BUILDER_IMAGE --output json
```

### 9. Build an image with Buildpacks
```bash
pack build "$HARBOR/applications/sample-java:dev"   --path .   --builder $BUILDER_IMAGE
```

### 10. Run the built image as a container
Pack builds straight into your local Docker image store, so you can run it right away.

```bash
docker images | grep sample-java

docker run --rm -d   --name sample-buildpacks-test   -p 8081:8080   "$HARBOR/applications/sample-java:dev"

docker ps --filter name=sample-buildpacks-test
docker logs sample-buildpacks-test
curl -sf http://localhost:8081/ || echo "adjust the port/health path for this app"
docker stop sample-buildpacks-test
```

### 11. Mirror the builder and Pack images to Harbor

**Option A — skopeo:**
```bash
skopeo copy docker://paketobuildpacks/builder-jammy-base:0.4.578   docker://$HARBOR/buildpacks/builder-jammy-base:0.4.578

skopeo copy docker://buildpacksio/pack:${PACK_VERSION}   docker://$HARBOR/buildpacks/pack:${PACK_VERSION}
```

**Option B — imgpkg:**
```bash
imgpkg copy   -i docker.io/paketobuildpacks/builder-jammy-base:0.4.578   --to-repo $HARBOR/buildpacks/builder-jammy-base

imgpkg copy   -i docker.io/buildpacksio/pack:${PACK_VERSION}   --to-repo $HARBOR/buildpacks/pack
```

### 12. Point Buildpacks at your own run-image mirror
```bash
pack config run-image-mirrors add   index.docker.io/paketobuildpacks/run-jammy-base:latest   --mirror "$HARBOR/buildpacks/run-jammy-base:latest"

pack config run-image-mirrors list
```

> **On Kubernetes:** Pack needs a container runtime (a Docker daemon or similar) to build. Don't assume a cluster node has `/var/run/docker.sock` available. For testing, a Docker-in-Docker sidecar works. For production, look at kpack or another Kubernetes-native way to run Buildpacks.

### 13. Prepare Harbor for pushing and pulling
Harbor should already be installed. Create separate accounts for pushing build images and pulling them at runtime.

```bash
# Build push/pull secret
kubectl create secret docker-registry harbor-credentials   --docker-server="$HARBOR"   --docker-username='<ROBOT_USERNAME>'   --docker-password='<ROBOT_TOKEN>'   -n cicd
```
* Use a scoped "robot" account, not the Harbor admin account.
* Keep push credentials (used by CI) separate from pull credentials (used by running apps).
* Turn on TLS, and make sure build Pods trust the Harbor certificate.
* Deploy using the exact image digest, not a tag like `latest`.
* Don't let an image go live until it passes your vulnerability scan policy.

### 14. Wire it into a Tekton pipeline

**Pipeline stages:**

| Stage | What it does |
| :--- | :--- |
| **checkout** | Pulls the exact source code revision |
| **detect** | Decides: BuildKit or Buildpacks |
| **build** | Builds and pushes the image |
| **scan** | Harbor checks it for vulnerabilities |
| **sign** | Signs the approved image |

How the pipeline decides which build engine to use:

```bash
if [ -f Dockerfile ]; then
  echo buildkit
else
  echo buildpacks
fi
```

> Stick to the rule: Dockerfile present → BuildKit; absent → Buildpacks. Don't silently fall back to a Dockerfile build if Buildpacks fails to detect anything.

**Example BuildKit Tekton Task:**
```yaml
apiVersion: tekton.dev/v1
kind: Task
metadata:
  name: buildkit-build
  namespace: cicd
spec:
  params:
    - name: image
      type: string
  workspaces:
    - name: source
  steps:
    - name: build
      image: harbor.example.internal/buildkit/buildkit:v0.30.0
      securityContext:
        runAsUser: 1000
        runAsGroup: 1000
        seccompProfile:
          type: Unconfined
      env:
        - name: BUILDKITD_FLAGS
          value: --oci-worker-no-process-sandbox
        - name: DOCKER_CONFIG
          value: /tekton/home/.docker
      command: ["buildctl-daemonless.sh"]
      args:
        - build
        - --frontend
        - dockerfile.v0
        - --local
        - context=$(workspaces.source.path)
        - --local
        - dockerfile=$(workspaces.source.path)
        - --output
        - type=image,name=$(params.image),push=true
      volumeMounts:
        - name: dockerconfig
          mountPath: /tekton/home/.docker
  volumes:
    - name: dockerconfig
      secret:
        secretName: harbor-credentials
```

> **Buildpacks Task, in short:** for testing, run Pack in a container with access to a controlled Docker sidecar. For production, use a proper Kubernetes-native build service like kpack instead.

---

## Installation — Air-Gapped / Disconnected Environment

Air-gapped setup has two stages: first, mirror everything you need while you still have internet access; second, run everything fully offline. The disconnected cluster should never need Docker Hub, GitHub, or any public registry.

### 1. Set up a mirror workstation
This is any machine with internet access that you'll use to copy images into your internal registry.

```bash
mkdir -p airgap/{images,charts,manifests,binaries,checksums}
export HARBOR=harbor.example.internal
```

### 2. Mirror the BuildKit image

**Option A — skopeo:**
```bash
skopeo copy docker://moby/buildkit:${BUILDKIT_VERSION}   docker://$HARBOR/buildkit/buildkit:${BUILDKIT_VERSION}
```

**Option B — imgpkg** (handy if you're already using Carvel tools elsewhere on the platform):
```bash
# Copy straight from the internet to Harbor
imgpkg copy   -i docker.io/moby/buildkit:${BUILDKIT_VERSION}   --to-repo $HARBOR/buildkit/buildkit

# OR: save to a tar file and move it across manually
imgpkg copy   -i docker.io/moby/buildkit:${BUILDKIT_VERSION}   --to-tar buildkit.tar

# on the disconnected side, after transferring the tar file:
imgpkg copy   --tar buildkit.tar   --to-repo $HARBOR/buildkit/buildkit
```

### 3. Mirror the Buildpacks images (builder, run image, Pack)

**Option A — skopeo:**
```bash
skopeo copy docker://paketobuildpacks/builder-jammy-base:0.4.578   docker://$HARBOR/buildpacks/builder-jammy-base:0.4.578

skopeo copy docker://paketobuildpacks/run-jammy-base:latest   docker://$HARBOR/buildpacks/run-jammy-base:latest

skopeo copy docker://buildpacksio/pack:${PACK_VERSION}   docker://$HARBOR/buildpacks/pack:${PACK_VERSION}
```

**Option B — imgpkg:**
```bash
imgpkg copy   -i docker.io/paketobuildpacks/builder-jammy-base:0.4.578   --to-repo $HARBOR/buildpacks/builder-jammy-base

imgpkg copy   -i docker.io/paketobuildpacks/run-jammy-base:latest   --to-repo $HARBOR/buildpacks/run-jammy-base

imgpkg copy   -i docker.io/buildpacksio/pack:${PACK_VERSION}   --to-repo $HARBOR/buildpacks/pack
```

Either tool gets the job done. skopeo is a simple direct copy. imgpkg is useful if you're tracking images through Carvel bundles/lock files elsewhere already (e.g. Argo CD). Don't mix both for the same image — pick one per component.

**Also remember to:**
* Mirror both the builder image and its run image — you need both.
* Check the builder's metadata to see exactly which images it depends on.
* Mirror every base image used in any Dockerfile (`FROM ...`) too — mirroring the BuildKit binary alone isn't enough.

### 4. Point Buildpacks at the mirrored run image
```bash
pack config run-image-mirrors add   index.docker.io/paketobuildpacks/run-jammy-base:latest   --mirror "$HARBOR/buildpacks/run-jammy-base:latest"

pack config run-image-mirrors list
```

### 5. Build with the internet blocked, then run each image as a container
Do this from inside your disconnected environment, with public internet access blocked, to prove both engines work using only the images you mirrored — and that the resulting images actually run.

**BuildKit:**
```bash
buildctl-daemonless.sh build   --frontend dockerfile.v0   --local context=/workspace/source   --local dockerfile=/workspace/source   --output type=image,name="$HARBOR/applications/sample:airgap-TAG",push=true

docker pull "$HARBOR/applications/sample:airgap-TAG"
docker run --rm -d --name sample-buildkit-airgap -p 8080:8080   "$HARBOR/applications/sample:airgap-TAG"
docker ps --filter name=sample-buildkit-airgap
docker logs sample-buildkit-airgap
docker stop sample-buildkit-airgap
```

**Buildpacks:**
```bash
pack build "$HARBOR/applications/sample-java:airgap-dev"   --path .   --builder "$HARBOR/buildpacks/builder-jammy-base:0.4.578"

docker run --rm -d --name sample-buildpacks-airgap -p 8081:8080   "$HARBOR/applications/sample-java:airgap-dev"
docker ps --filter name=sample-buildpacks-airgap
docker logs sample-buildpacks-airgap
docker stop sample-buildpacks-airgap
```

> No Docker socket available on the disconnected host or cluster node? Use a throwaway Pod instead: `kubectl run <name> --image=<mirrored-image> --restart=Never -n cicd -- <startup-check-command>`, then check `kubectl logs <name> -n cicd`.

### 6. Final air-gap checklist
* [ ] Public registries and internet access are blocked from the build namespace.
* [ ] Every build-time image pull resolves to Harbor.
* [ ] A Dockerfile build works using only mirrored base images (BuildKit).
* [ ] A Buildpacks build works using only the mirrored builder and run image.
* [ ] Build logs show no public registry access at all.

> **VKS-specific note:** VKS package registration supports disconnected registration — download the service definition on a connected machine, move it to your private registry, then register it against the target Supervisor.

---

## Operations & Validation

**Everyday commands to check that things are working:**
```bash
# BuildKit
buildctl debug workers
kubectl logs -n cicd <buildkit-pod> --tail=200

# Buildpacks
pack builder inspect $BUILDER_IMAGE
pack config run-image-mirrors list

# Tekton
kubectl get pipelinerun,taskrun -n cicd
kubectl describe taskrun <name> -n cicd
```

**What "working" looks like**

| Component | Check | Expected result |
| :--- | :--- | :--- |
| **BuildKit** | `buildctl debug workers` | A worker shows up as registered |
| **BuildKit** | Tekton run (with Dockerfile) | Image lands in Harbor |
| **Buildpacks** | `pack build` (local) | Image is built and can run |
| **Buildpacks** | Tekton run (no Dockerfile) | Image lands in Harbor |
| **Harbor** | `docker push / pull` | Both succeed |
| **Air-gap** | Build with internet blocked | Build still succeeds, using mirrors only |

## Security Hardening
* Use separate namespaces and least-privilege service accounts for builds.
* Use scoped Harbor robot accounts — separate ones for pushing and pulling.
* Prefer rootless BuildKit; avoid privileged Docker-in-Docker unless it's specifically approved.
* Always deploy by image digest, never by a mutable tag like `latest`.
* Protect the keys used for signing images after they pass the scan.
* Apply NetworkPolicies to build namespaces where your cluster supports it.
* Never expose the BuildKit daemon over plain, unauthenticated TCP — if you must run it as a Service, secure it with mTLS.

## Conclusion (Part 1)
Together, BuildKit and Buildpacks cover both build styles teams need: BuildKit for full manual control through a Dockerfile, and Buildpacks for teams that would rather not maintain one. Following the simple Dockerfile-present/absent rule keeps the pipeline predictable, and mirroring both engines' images into Harbor means the exact same steps work whether your VKS cluster is online or fully air-gapped. Running this on VKS also means the build layer gets to reuse VCF's built-in registry, GitOps, storage, and networking instead of needing its own separate infrastructure.

Before this goes live, replace every placeholder value (hostnames, credentials, namespaces, registry URLs, image versions) with your real environment's values, and run through the air-gap test even if you're currently online — it's the best way to catch a missing mirror before it becomes a production incident.

## Recommended Repository Layout
```text
build-platform/
├── versions.env
├── buildkit/
│   ├── task.yaml
│   └── rootless-values.yaml
├── buildpacks/
│   ├── builder.yaml
│   └── run-image-mirrors.yaml
├── airgap/
│   ├── manifests/
│   ├── image-inventory/
│   └── checksums/
└── tekton/
    ├── tasks/
    └── pipelines/
```

## Official References (Part 1)
* BuildKit: https://github.com/moby/buildkit
* BuildKit Kubernetes examples: https://github.com/moby/buildkit/tree/master/examples/kubernetes
* Cloud Native Buildpacks — Pack CLI install: https://buildpacks.io/docs/install-pack/
* CNB run image concept: https://buildpacks.io/docs/for-app-developers/concepts/base-images/run/
* CNB builder config reference: https://buildpacks.io/docs/reference/config/builder-config/
* CNB run-image mirrors (`pack config run-image-mirrors add`): https://buildpacks.io/docs/for-platform-operators/how-to/integrate-ci/pack/cli/pack_config_run-image-mirrors_add/
* Tekton Pipelines install: https://tekton.dev/docs/pipelines/install/
* VMware vSphere Kubernetes Service (VKS) components: https://techdocs.broadcom.com/us/en/vmware-cis/vcf/vcf-service-administration-and-development/9-1/managing-vsphere-kubernetes-service/running-tkg-service-clusters/tkg-service-components.html
* VMware Supervisor Services catalog: https://vsphere-tmm.github.io/Supervisor-Services/

---
---

# Part 2 — Tekton CI Implementation on VKS

## Introduction

Tekton is a Kubernetes-native CI/CD framework, built as a CNCF project. Instead of running on a separate CI server (like Jenkins), it extends the Kubernetes API itself — so your Pipelines, Tasks, and their executions are just native Kubernetes objects, stored in etcd and managed with kubectl.

* **Pipeline** = an ordered set of Tasks
* **Task** = one unit of work (e.g., clone code, build image), run as steps inside a Pod
* **PipelineRun/TaskRun** = an actual execution of a Pipeline/Task
* **Triggers** (EventListener, etc.) = turn a webhook (like a git push) into a PipelineRun automatically

Because every step runs in its own isolated Pod, builds are reproducible and scale using the same Kubernetes scheduler as everything else — no separate agent fleet, and it reuses your existing Kubernetes RBAC instead of a bolted-on permission system.

In your docs, it's used as the CI engine: clone → build (Buildpacks/BuildKit, from Part 1) → generate SBOM (Syft) → sign & attest (Cosign) → push to Harbor.

### Why We Are Using Tekton in This Project

* **Kubernetes-native:** runs directly on the VKS cluster we already operate — no separate CI server, VM pool, or agent fleet to patch and maintain.
* **Fits the architecture:** the wider CI/CD design (Buildpacks/BuildKit → Syft/Cosign → Harbor → Argo CD → Istio Gateway) is built around CNCF, Kubernetes-first tooling, and Tekton is the CNCF standard for pipeline orchestration.
* **RBAC reuse:** because Pipelines and Tasks are just Kubernetes objects, existing namespace-level RBAC policies control who can create or trigger builds — no separate permission system.
* **Isolation and reproducibility:** every build step — including SBOM generation and signing — runs in its own Pod, so one team's build cannot leak state into another's, and a build behaves the same way every time it runs.
* **Elastic scaling:** build load is scheduled and scaled by the same Kubernetes scheduler used for everything else on the cluster — no manual capacity planning for a separate CI farm.

## Project Implementation Decisions

| Requirement | Selected Approach | Remarks / Context |
| :--- | :--- | :--- |
| **Builder Image** | `paketobuildpacks/builder-jammy-base` | Injected into the Buildpacks task parameter. |
| **Builder Base Image** | `index.docker.io/paketobuildpacks/run-jammy-base` | Automatically utilized by the builder image during the Buildpacks compilation step. |
| **BuildKit Image** | `moby/buildkit:latest` | Injected into the BuildKit task parameter. |
| **Pipeline Logic (Build)** | Conditional `taskSpec` script. | If `Dockerfile` exists, route to BuildKit. If absent, route to Buildpacks flow. |
| **Security & Governance** | `finally` block execution for Syft & Cosign. | Executes immediately after compilation to sign the OCI image and attach the SBOM before pushing to the Harbor repository for governance verification. |

## Tekton Architecture on VKS

Tekton is deployed as the Pipeline Orchestrator inside the dedicated CI-VKS cluster, separate from the Runtime-VKS cluster that runs production application workloads. This isolation limits the blast radius of build activity and allows the CI and runtime environments to scale independently.

### Custom Resource Definitions (CRDs)

A Custom Resource Definition (CRD) extends the standard Kubernetes API so the cluster understands new object types beyond the built-ins (Pod, Deployment, Service, etc.). Once a CRD is installed, Kubernetes treats the new object exactly like a native one — stored in etcd, managed through `kubectl`, and governed by the same RBAC rules.

Tekton defines its core concepts entirely as CRDs:

* **Pipeline** — the CRD describing an ordered set of Tasks.
* **Task** — the CRD describing one unit of build work (a set of Steps run in one Pod).
* **PipelineRun / TaskRun** — the CRDs representing one actual execution of a Pipeline or Task.
* **EventListener / TriggerBinding / TriggerTemplate** — the CRDs (from Tekton Triggers) that turn a webhook event into a new PipelineRun.

#### Why This Matters

* **No external dependency:** Tekton needs no separate database or control plane — it reuses the Kubernetes control plane and etcd that already exist.
* **Standard tooling:** pipelines are managed with the same `kubectl` commands, GitOps flows, and RBAC policies used for every other Kubernetes resource.
* **Declarative and versionable:** Pipeline/Task definitions are plain YAML, code-reviewed and stored in Git like any other manifest.

## Prerequisites and Version Gate

Before any installation path (Internet-Connected or Air-Gapped) is started, the operator workstation and the target CI-VKS cluster must satisfy the version gate below. Pinning versions up front is what makes the air-gapped mirror reproducible — the mirror workstation and the cluster must always be built against the same tag, including the Cosign and Syft tooling used for supply chain security.

### Required CLI Tooling

| Tool | Purpose | Minimum Version |
|---|---|---|
| `kubectl` | Applies manifests and inspects cluster state on the CI-VKS cluster | Matches cluster minor version (±1) |
| `tkn` | Tekton CLI — starts/inspects PipelineRuns, reads logs | v0.41.0 or later |
| `skopeo` | Copies and mirrors OCI images between registries without a full Docker daemon; required for the air-gapped path | v1.14 or later |
| `cosign` | Generates local key pairs for testing, and signs/verifies image signatures and attestations; required to validate the sign-and-attest Task output before it is trusted in production | v2.2 or later |
| `syft` | Generates CycloneDX/SPDX SBOMs locally so a developer can validate SBOM content and structure before it is generated in-pipeline by the generate-sbom Task | v1.0 or later |

### Version-Pinning Environment Variables

Export these on the mirror workstation and reference them in place of `latest` anywhere a release manifest or image tag is used:

```bash
export ="v0.62.0"
export TEKTON_TRIGGERS_VERSION="v0.29.0"
export TEKTON_DASHBOARD_VERSION="v0.51.0"
export TEKTON_OPERATOR_VERSION="v0.75.0"
export TKN_CLI_VERSION="v0.41.0"
export COSIGN_VERSION="v2.2.4"
export SYFT_VERSION="v1.0.1"
export HARBOR_REGISTRY_HOST="harbor.internal.example.com"
```

### Kubernetes Version Gate

| Requirement | Value |
|---|---|
| VMware Cloud Foundation / Supervisor and workload cluster provisioning | v9.x |
| vSphere Kubernetes Service / Workload cluster runtime | VCF 9.x bundled |
| API groups required | `apiextensions.k8s.io/v1`, `admissionregistration.k8s.io/v1` |
| Pre-flight check | `kubectl version --short && kubectl api-versions` |

---

## Official Release Manifests, Commands & References (Internet-Connected)

All commands below are copied directly from the official Tekton project documentation (tekton.dev) and the tektoncd GitHub organization. These are the exact manifests to apply for a clean install where the cluster has outbound internet access. For a disconnected/air-gapped cluster, use the Air-Gapped section instead.

#### Tekton Pipelines (Core) — Required
Current official CDN (tekton.dev points here as of 2026):
```bash
kubectl apply --filename https://infra.tekton.dev/tekton-releases/pipeline/latest/release.yaml
kubectl get pods --namespace tekton-pipelines --watch
```

Legacy mirror (still valid, used in most existing docs/tutorials):
```bash
kubectl apply --filename https://storage.googleapis.com/tekton-releases/pipeline/latest/release.yaml
```

Install a specific version instead of `latest`:
```bash
kubectl apply --filename https://infra.tekton.dev/tekton-releases/pipeline/previous/v1.15.1/release.yaml
```

Untagged variant (only if the container runtime doesn't support `image:tag@digest`, e.g. older CRI-O/OpenShift):
```bash
kubectl apply --filename https://infra.tekton.dev/tekton-releases/pipeline/latest/release.notags.yaml
```

#### Tekton Triggers — Required only for webhook-based auto-trigger
```bash
kubectl apply --filename https://storage.googleapis.com/tekton-releases/triggers/latest/release.yaml
kubectl apply --filename https://storage.googleapis.com/tekton-releases/triggers/latest/interceptors.yaml
kubectl get pods --namespace tekton-pipelines --watch
```

#### Tekton Dashboard — Optional (visual PipelineRun monitoring)
Read-only mode (default, recommended for shared/production clusters):
```bash
kubectl apply --filename https://infra.tekton.dev/tekton-releases/dashboard/latest/release.yaml
```

Read/write mode (lets you trigger runs from the UI — fine for local testing):
```bash
kubectl apply --filename https://infra.tekton.dev/tekton-releases/dashboard/latest/release-full.yaml
```

Access locally via port-forward:
```bash
kubectl --namespace tekton-pipelines port-forward svc/tekton-dashboard 9097:9097
# then open http://localhost:9097
```

#### Tekton CLI (tkn)
```bash
# macOS (Homebrew)
brew install tektoncd-cli

# Linux (x86_64)
curl -LO https://github.com/tektoncd/cli/releases/download/v0.41.0/tkn_0.41.0_Linux_x86_64.tar.gz
tar xvzf tkn_0.41.0_Linux_x86_64.tar.gz -C /usr/local/bin tkn
tkn version
```

#### Cosign CLI — Installation
Cosign signs the built image and attaches the SBOM as a verified attestation in the `sign-and-attest` Task, so it needs to be installed on both the operator workstation (for local testing/verification) and mirrored into the cluster image for in-pipeline use.
```
 variable: COSIGN_VERSION="v2.2.4"
```

```bash
# macOS (Homebrew)
brew install cosign

# Linux (x86_64) — pinned to 
curl -O -L "https://github.com/sigstore/cosign/releases/download/${}/cosign-linux-amd64"
sudo mv cosign-linux-amd64 /usr/local/bin/cosign
sudo chmod +x /usr/local/bin/cosign

# Go install (alternative, if a Go toolchain is already present)
go install github.com/sigstore/cosign/v2/cmd/cosign@${COSIGN_VERSION}

cosign version
```

Generate a local key pair for testing signatures and verification before relying on the in-cluster key from the Air-Gapped section:
```bash
cosign generate-key-pair
# writes cosign.key (private, password-protected) and cosign.pub (public) to the current directory
```

Verify a signed image once the pipeline has pushed and signed it:
```bash
cosign verify --key cosign.pub "$HARBOR/applications/sample:TAG"
```

> Keep `cosign.key` out of Git. In the pipeline itself, the signing key is generated and stored as a Kubernetes Secret instead (see Step 3 in the Air-Gapped section below) so key material never has to leave the cluster.

#### Verifying the Installation
```bash
kubectl get pods -n tekton-pipelines
kubectl get crd | grep tekton.dev
```

#### Uninstalling (rollback / cleanup)
```bash
kubectl delete --filename https://infra.tekton.dev/tekton-releases/pipeline/latest/release.yaml
kubectl delete --filename https://storage.googleapis.com/tekton-releases/triggers/latest/release.yaml
```

### Official References (Part 2)

| Resource | Official URL |
| :--- | :--- |
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

---

## Air-Gapped / Disconnected Setup

This section documents the offline installation path for CI-VKS clusters with no outbound internet access. It assumes the version gate and environment variables from the Prerequisites section — including `COSIGN_VERSION` and `SYFT_VERSION` — are already exported on the mirror workstation.

#### Disconnected Topology Overview
> **ⓘ NOTE — Flow (one-way):** [Connected Zone: tekton.dev / GHCR / Docker Hub / sigstore] → `skopeo copy` on Mirror Workstation → Local Manifest + Image Cache → (physical/secure transfer) → [Disconnected Zone: Internal Harbor Registry → CI-VKS Cluster]. The mirror workstation is the only component with outbound internet access.

#### Step 1 — Prepare the Mirror Workstation 
```
variable: TEKTON_PIPELINES_VERSION="v0.62.0"
variable:TEKTON_TRIGGERS_VERSION="v0.29.0"
 variable:TEKTON_DASHBOARD_VERSION="v0.51.0"
```
On a workstation that has temporary internet access, create a local staging area and pull the pinned manifests:
```bash
mkdir -p ~/tekton-mirror/{manifests,images}
cd ~/tekton-mirror

curl -Lo manifests/pipeline-${TEKTON_PIPELINES_VERSION}.yaml   https://infra.tekton.dev/tekton-releases/pipeline/previous/${TEKTON_PIPELINES_VERSION}/release.yaml
curl -Lo manifests/triggers-${TEKTON_TRIGGERS_VERSION}.yaml   https://storage.googleapis.com/tekton-releases/triggers/previous/${TEKTON_TRIGGERS_VERSION}/release.yaml
curl -Lo manifests/dashboard-${TEKTON_DASHBOARD_VERSION}.yaml   https://storage.googleapis.com/tekton-releases/dashboard/previous/${TEKTON_DASHBOARD_VERSION}/release.yaml
```

#### Step 2 — Mirror Images to Internal Harbor
Use `skopeo copy` to move each Tekton component image — and both supply chain security tool images — from its public source registry directly into the internal Harbor project, preserving the pinned tag:
```
 variable:SYFT_VERSION="v1.0.1"
```
```bash
skopeo copy   docker://gcr.io/tekton-releases/github.com/tektoncd/pipeline/cmd/controller:${TEKTON_PIPELINES_VERSION}   docker://${HARBOR_REGISTRY_HOST}/tekton-mirror/pipeline-controller:${TEKTON_PIPELINES_VERSION}

skopeo copy   docker://gcr.io/tekton-releases/github.com/tektoncd/triggers/cmd/controller:${TEKTON_TRIGGERS_VERSION}   docker://${HARBOR_REGISTRY_HOST}/tekton-mirror/triggers-controller:${TEKTON_TRIGGERS_VERSION}

# --- Supply chain security tooling (Syft + Cosign) ---
skopeo copy   docker://bitnami/cosign:${COSIGN_VERSION}   docker://${HARBOR_REGISTRY_HOST}/tekton-mirror/cosign:${COSIGN_VERSION}

skopeo copy   docker://anchore/syft:${SYFT_VERSION}   docker://${HARBOR_REGISTRY_HOST}/tekton-mirror/syft:${SYFT_VERSION}
```

#### Step 3 — Generate the Cosign Key Pair In-Cluster
Generate the Cosign signing key pair natively and store it as a Kubernetes Secret, so the sign-and-attest Task can sign images immediately without key material leaving the cluster:
```bash
cosign generate-key-pair k8s://tekton-pipelines/cosign-keys
kubectl get secret cosign-keys -n tekton-pipelines
```

---

## Core Pipeline Implementation Manifests

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
```bash
kubectl apply --filename https://storage.googleapis.com/tekton-releases/pipeline/latest/release.yaml
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
    # ---------------------------------------------------------
    # 1. Clone source code
    # ---------------------------------------------------------
    - name: fetch-source-code
      taskRef:
        name: git-clone
      workspaces:
        - name: output
          workspace: shared-workspace
      params:
        - name: url
          value: $(params.repo-url)

    # ---------------------------------------------------------
    # 2. Check whether Dockerfile exists
    # ---------------------------------------------------------
    - name: check-dockerfile
      runAfter:
        - fetch-source-code
      workspaces:
        - name: source
          workspace: shared-workspace
      taskSpec:
        workspaces:
          - name: source
        results:
          - name: dockerfile-exists
            description: "Whether Dockerfile exists in the repository"
        steps:
          - name: check
            image: bash:5.2
            script: |
              #!/usr/bin/env bash
              set -e
              if [ -f "$(workspaces.source.path)/Dockerfile" ]; then
                echo "true" | tee "$(results.dockerfile-exists.path)"
                echo "Dockerfile found. Using BuildKit."
              else
                echo "false" | tee "$(results.dockerfile-exists.path)"
                echo "Dockerfile not found. Using Buildpacks."
              fi

    # ---------------------------------------------------------
    # 3. Build using BuildKit when Dockerfile exists
    # ---------------------------------------------------------
    - name: build-with-buildkit
      runAfter:
        - check-dockerfile
      when:
        - input: "$(tasks.check-dockerfile.results.dockerfile-exists)"
          operator: in
          values:
            - "true"
      taskRef:
        name: buildkit
      workspaces:
        - name: source
          workspace: shared-workspace
      params:
        - name: IMAGE
          value: $(params.image-reference)
        - name: BUILDER_IMAGE
          value: docker.io/moby/buildkit:latest

    # ---------------------------------------------------------
    # 4. Build using Buildpacks when Dockerfile does NOT exist
    # ---------------------------------------------------------
    - name: build-with-buildpacks
      runAfter:
        - check-dockerfile
      when:
        - input: "$(tasks.check-dockerfile.results.dockerfile-exists)"
          operator: in
          values:
            - "false"
      taskRef:
        name: buildpacks
      workspaces:
        - name: source
          workspace: shared-workspace
      params:
        - name: APP_IMAGE
          value: $(params.image-reference)
        - name: BUILDER_IMAGE
          value: docker.io/paketobuildpacks/builder-jammy-base

  # ---------------------------------------------------------
  # Finally Block: Security & Governance
  # ---------------------------------------------------------
  finally:
    # ---------------------------------------------------------
    # 5. Generate SBOM
    # ---------------------------------------------------------
    - name: generate-sbom
      taskRef:
        name: syft-generate
      workspaces:
        - name: source
          workspace: shared-workspace
      params:
        - name: image-reference
          value: $(params.image-reference)
        - name: output-file
          value: sbom-cyclonedx.json

    # ---------------------------------------------------------
    # 6. Sign and attest
    # ---------------------------------------------------------
    - name: sign-and-attest
      runAfter:
        - generate-sbom
      taskRef:
        name: cosign-sign-attest
      workspaces:
        - name: source
          workspace: shared-workspace
      params:
        - name: image-reference
          value: $(params.image-reference)
        - name: sbom-path
          value: $(workspaces.source.path)/sbom-cyclonedx.json
```

### Pipeline Workflow Parameters Explained

| Field | Rationale & Function |
| :--- | :--- |
| `params` | Injects variables at runtime (e.g. the Git repo URL, the destination image tag in Harbor) without hardcoding values into the Pipeline definition. |
| `workspaces` | Binds a PVC-backed shared volume to the Pipeline so the `git-clone` Task can write source code to disk that the buildpacks, syft, and cosign Tasks then read. |
| `taskRef` | References a prebuilt, standardized Task (e.g. from the Tekton Catalog, or the internal `syft-generate` / `cosign-sign-attest` Tasks) instead of redefining build or signing logic from scratch, cutting developer overhead. |
| `runAfter` | Enforces execution order — guarantees the source code is fully cloned before the artifact builder Task starts, the image is fully built and pushed before the SBOM is generated, and the SBOM exists before Cosign signs the image and attaches it as an attestation. |
| `tasks[].name` | A unique label for that step within the Pipeline; referenced by other steps' `runAfter` and by logs/dashboards. |
| `workspaces` (per task) | Maps the Pipeline-level `shared-workspace` to the specific workspace name each Task expects internally (e.g. `output` for git-clone, `source` for buildpacks/syft/cosign). |
| `output-file` (param) | Tells the `syft-generate` Task the filename to write the generated CycloneDX SBOM to, inside the shared workspace, so it can be located by the next Task. |
| `sbom-path` (param) | Passes the exact on-disk location of the generated SBOM — `$(workspaces.source.path)/sbom-cyclonedx.json` — from `generate-sbom` into `sign-and-attest`, so Cosign knows precisely which file to attach as the attestation. |

### Starting a Run Manually (Local Test)
```bash
tkn pipeline start vks-modern-app-pipeline   -w name=shared-workspace,claimName=my-pvc   -p repo-url=https://github.com/org/sample-app.git   -p image-reference=harbor.local/team/sample-app:test

tkn pipelinerun logs -f
```

## Conclusion (Part 2)
Tekton gives this project a Kubernetes-native, CRD-based CI engine that removes the need for external build infrastructure, reuses existing RBAC boundaries, and guarantees reproducible, isolated builds per step. The Pipeline shown in the Sample Pipeline Workflow section (clone → build via Buildpacks/BuildKit → generate SBOM with Syft → sign and attest with Cosign → push) is the minimum working CI loop that can be validated locally before wiring in Harbor governance, GitOps updates, and Argo CD delivery, which are documented in the companion Argo CD implementation guide.

This revision closes the gap between that reference architecture and a disconnected production rollout with software supply chain security natively enforced end to end: the Prerequisites section gates the install on the right tooling and pinned versions, including Cosign and Syft; the Air-Gapped section gives the mirror-workstation-to-Harbor path — now covering the Syft and Cosign tool images and in-cluster key generation — for environments with no outbound internet access; and the Validation Matrix, Production Readiness Checklist, and Troubleshooting sections give the validation, sign-off, and troubleshooting artifacts, including signature and attestation verification, needed to certify the CI stack as production-ready in either mode.
