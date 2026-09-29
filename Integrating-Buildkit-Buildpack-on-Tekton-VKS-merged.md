# BuildKit & Cloud Native Buildpacks on vSphere Kubernetes Service (VKS)

> **In one line:** this document explains how we automatically turn a developer's code into a
> secure, signed container image — and do it the same way whether the app has a `Dockerfile`
> or not — using **Tekton** as the automation engine, running on **VMware VKS**.

---

## Introduction

When a developer writes an application, that application needs to be packaged into a
**container image** before it can run on Kubernetes. There are two ways we package it here:

- **BuildKit** — used when the app's repository already has a `Dockerfile`. Think of a
  `Dockerfile` as a recipe card the developer wrote themselves, listing every step needed to
  build the image. BuildKit just follows that recipe exactly.
- **Cloud Native Buildpacks (Buildpacks, via the Pack CLI / Tekton lifecycle)** — used when
  there's **no** `Dockerfile`. Instead of a recipe card, Buildpacks looks at the code itself
  (is it Java? Python? Go?) and figures out on its own how to package it, using pre-built,
  well-tested building blocks.

The simple rule we follow everywhere in this platform:

> **Repo has a `Dockerfile` → use BuildKit.**
> **Repo has no `Dockerfile` → use Buildpacks.**

**Tekton** is the piece that makes this automatic. Every time a developer pushes code, Tekton
wakes up, checks whether there's a `Dockerfile`, picks the right tool (BuildKit or
Buildpacks), builds the image, generates a paper trail for it (a **Software Bill of
Materials**, or SBOM — basically an ingredients list for the image), **digitally signs** both
the image and that ingredients list using **Cosign**, and pushes everything to our internal
image store, **Harbor**. No person has to do any of these steps by hand.

This document covers both:
1. How BuildKit and Buildpacks build images.
2. How Tekton runs and automates that whole process on VKS — including in a fully offline
   ("air-gapped") environment.

---

## Why use BuildKit and Buildpacks with Tekton on VKS?

In plain terms, here's why this combination makes sense:

- **One automatic process for everyone.** Whether or not a team wrote a `Dockerfile`, their
  code still gets built the same reliable way — Tekton decides which tool to use, so nobody
  has to remember or configure it manually.
- **Nothing gets built by hand.** A person pushing code is the only manual step. Everything
  after that — building, checking for security issues, signing, publishing — happens on its
  own.
- **Trust is built in, not bolted on.** Every image gets signed and gets an ingredients list
  (SBOM) the moment it's built — not added later as an afterthought. Harbor can then refuse to
  hand out any image that isn't signed.
- **It all runs on the same platform.** VKS already gives us the cluster, the storage, the
  networking, Harbor (image store), and ArgoCD (deployment) — Tekton just plugs into what's
  already there instead of needing its own separate servers.
- **Works with no internet too.** Everything described here — BuildKit, Buildpacks, Tekton,
  and Cosign — can run fully offline, which matters for secure/air-gapped environments.
- **One dashboard to watch it all.** Tekton's Dashboard shows every build, whether it succeeded
  or failed, and why — in a web page, not just log files.

---

## Benefits

| Benefit | In simple words |
|---|---|
| **No guesswork on how to build** | Tekton always knows: `Dockerfile` present → BuildKit, absent → Buildpacks. |
| **Less work for app teams** | Teams don't need to write or maintain a `Dockerfile` if they don't want to — Buildpacks handles it for them. |
| **Fully automatic** | A code push is the only human action; the build, sign, and publish steps run by themselves. |
| **Every image is signed** | Cosign signs the image and its ingredients list (SBOM) right after it's built, so nothing unverified reaches production. |
| **Safer builds** | BuildKit and Buildpacks both run without needing root/admin access inside the cluster. |
| **One place for images** | Every built image lands in Harbor, where it's scanned, verified, and stored. |
| **Same steps everywhere** | The exact same pipeline works whether the cluster has internet access or is completely offline. |
| **You can always prove what's running** | Images are tracked by a fixed ID (a digest), not a name that can change, and each one has a matching signed ingredients list. |
| **One dashboard for visibility** | Anyone can open the Tekton Dashboard and see the status of every build, without needing cluster access. |

---

## Architecture

All of this — Tekton, BuildKit, Buildpacks, and Cosign — runs **inside the VKS cluster**
itself. Nothing extra needs to be installed outside it. Here's the whole journey from
"developer pushes code" to "signed image is deployed" — everything after step 1 happens
automatically, with no manual steps:

```
 1. Developer pushes code
             │
             ▼
 2. Tekton wakes up (triggered by the push)
             │
             ▼
 3. Tekton checks: does this repo have a Dockerfile?
             │
    ┌────────┴────────┐
   Yes                 No
    │                   │
    ▼                   ▼
 4a. BuildKit        4b. Buildpacks
 builds the image     builds the image
 (using the           (using paketo
  Dockerfile)          builder-jammy-base)
    │                   │
    └────────┬──────────┘
             ▼
 5. An ingredients list (SBOM) is created for the image
             │
             ▼
 6. The image AND the ingredients list are digitally
    signed with Cosign
             │
             ▼
 7. Everything is pushed to Harbor
    (Harbor scans it and checks the signature)
             │
             ▼
 8. Harbor stores the image with a fixed ID (digest)
             │
             ▼
 9. GitOps updates the deployment files, and ArgoCD
    deploys the new, signed image onto VKS
```

| Step | What it means in plain words |
|---|---|
| Developer pushes code | The only thing a person actually has to do |
| Tekton | The automation engine — watches for pushes and runs the whole pipeline |
| Dockerfile check | The one decision point: which tool builds the image |
| BuildKit / Buildpacks | The two ways an image actually gets built |
| SBOM (ingredients list) | A record of everything that went into the image, for security and audit |
| Cosign signing | Proves the image really came from our pipeline and hasn't been tampered with |
| Harbor | Where every image is stored, scanned, and checked for a valid signature |
| ArgoCD | Takes the newly signed image and rolls it out to the running application |

> **How "Tekton wakes up" (steps 1–2) is wired:** the push is delivered as a webhook to a Tekton
> `EventListener`, which filters it and starts the pipeline — see the *Automatic Triggering —
> Gitea Webhook → Tekton Triggers* section.

> **Where the Tekton Dashboard fits in:** it's a web page that shows you this entire journey —
> which step a build is on, whether it passed or failed, and the logs — without anyone needing
> direct access to the cluster.

---

## Prerequisites

### Platform

| Component | Version | What it's for |
|---|---|---|
| VMware Cloud Foundation (VCF) | 9.x | Sets up and manages the Supervisor and workload clusters |
| vSphere Kubernetes Service (VKS) | VCF 9.x bundled | Runs the actual Kubernetes workload cluster where builds happen |
| Regional Harbor | Installed via VCF Automation / Supervisor Service | Stores, scans, and signs images |
| Tekton Pipelines | Latest version supported by your cluster | Runs the CI pipeline — the automation engine described above |
| Tekton Dashboard | Same release train as Pipelines | The web page for watching build status |
| Cosign | Latest stable | Signs images and their ingredients lists (SBOMs) |
| Syft | Latest stable | Generates the ingredients list (SBOM) for each image |

> VCF and VKS ship together — this guide is pinned to **VCF 9.x**, with VKS bundled as part of
> that release. Every other version below (BuildKit, Pack, Tekton, Cosign, Syft) is validated
> against this VCF 9.x baseline — update them together, as a set, if you move to a newer VCF
> release.

### Tools needed on your build machine

```bash
kubectl version
kubectl cluster-info
kubectl get nodes -o wide

docker --version    # optional, only needed for local testing
helm version
git --version
curl --version
```

### Environment variables used in this guide

```bash
export HARBOR=harbor.example.internal
export CI_NS=cicd
export APP_NS=sample-app

# Versions validated against VCF 9.x / VKS — update together if you move to a newer VCF release
export PACK_VERSION=0.40.9
export BUILDER_IMAGE=paketobuildpacks/builder-jammy-base   # unpinned, matches requirement — always the latest
export RUN_IMAGE=index.docker.io/paketobuildpacks/run-jammy-base
export BUILDKIT_IMAGE=moby/buildkit:latest                 # per requirement — always the latest, not version-pinned
export TEKTON_VERSION=v0.62.2
export TRIGGERS_VERSION=v0.29.1
export DASHBOARD_VERSION=v0.50.0
export COSIGN_VERSION=v2.4.1
export SYFT_VERSION=v1.14.1
```

> **Before you install:** make sure your Kubernetes/VKS version supports the BuildKit and Pack
> versions above. Also check that your cluster nodes support running containers without root
> access ("rootless" mode) — that's what keeps BuildKit builds secure.
>
> **Note on `:latest`:** the builder, run, and BuildKit images are deliberately left unpinned
> here, per the platform requirement to always track the newest image. Everything else in this
> guide (VCF, VKS, Tekton, Pack CLI, Cosign, Syft) stays version-pinned for reproducibility —
> only these three images float.

---

## Required Add-ons Baseline

| Property | Baseline |
|---|---|
| Build tools | BuildKit (`moby/buildkit`) + Cloud Native Buildpacks (via Tekton's lifecycle, using the Pack builder) |
| Build selection rule | `Dockerfile` present → BuildKit; `Dockerfile` absent → Buildpacks |
| Automation engine | Tekton Pipelines + Triggers + Dashboard |
| Signing & trust | Cosign (signs images and SBOM attestations) + Syft (generates SBOMs) |
| Target platform | vSphere Kubernetes Service (VKS), bundled with VCF 9.x |
| Registry | Harbor (OCI registry, scanning, signing, and signature verification) |
| Automatic trigger | Gitea push webhook → Tekton Triggers (EventListener + CEL interceptor + TriggerBinding + TriggerTemplate) — see *Automatic Triggering* section |
| Default builder | `paketobuildpacks/builder-jammy-base` |
| Default run image | `index.docker.io/paketobuildpacks/run-jammy-base` (used automatically by the builder above) |
| BuildKit image | `moby/buildkit:latest` |
| Supported modes | Internet-connected **and** air-gapped/disconnected |

What has to already be in place before this build-and-sign pipeline is turned on:

- **Regional Harbor** — install and configure this first; it's where everything ends up.
- **Argo CD** — recommended, so a signed image can move straight to deployment through GitOps.
- **Contour or Istio Gateway** — used to expose the Tekton Dashboard securely, the same way
  application traffic is exposed.
- **cert-manager and external-dns** — give the Dashboard a real TLS certificate and DNS name,
  automatically.

### Set up namespaces

```bash
kubectl create namespace cicd --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace sample-app --dry-run=client -o yaml | kubectl apply -f -
```

---

## Installation — Internet-Connected Environment

This section installs everything needed while the cluster still has normal internet access.
Each step below says, in plain words, what it's actually doing before showing the command.

### 1. Install BuildKit — the tool that follows a `Dockerfile`

```bash
curl -fsSL -o buildkit.tar.gz \
  https://github.com/moby/buildkit/releases/latest/download/buildkit-linux-amd64.tar.gz

sudo tar -C /usr/local -xzf buildkit.tar.gz

buildctl --version
buildkitd --version
```

### 2. Try a BuildKit build by hand (to confirm it works)

```bash
buildctl-daemonless.sh build \
  --frontend dockerfile.v0 \
  --local context=/workspace/source \
  --local dockerfile=/workspace/source \
  --output type=image,name="$HARBOR/applications/sample:TAG",push=true
```

### 3. Send the BuildKit tool image itself to Harbor

So the cluster always pulls it from our own registry, not the public internet:

```bash
skopeo copy \
  docker://${BUILDKIT_IMAGE} \
  docker://$HARBOR/buildkit/buildkit:latest
```

### 4. Install the Pack CLI — the tool that runs Buildpacks

```bash
curl -sSL \
"https://github.com/buildpacks/pack/releases/download/v${PACK_VERSION}/pack-v${PACK_VERSION}-linux.tgz" \
  | sudo tar -C /usr/local/bin/ --no-same-owner -xzv pack

pack version
```

### 5. Look at the builder image before using it

The "builder" bundles everything Buildpacks needs to figure out how to package an app,
including which base ("run") image the final app will sit on top of:

```bash
pack builder inspect $BUILDER_IMAGE
```

### 6. Try a Buildpacks build by hand (to confirm it works)

```bash
pack build "$HARBOR/applications/sample-java:dev" \
  --path . \
  --builder $BUILDER_IMAGE
```

### 7. Send the builder and run images to Harbor

```bash
skopeo copy docker://${BUILDER_IMAGE} \
  docker://$HARBOR/buildpacks/builder-jammy-base:latest

skopeo copy docker://${RUN_IMAGE}:latest \
  docker://$HARBOR/buildpacks/run-jammy-base:latest
```

### 8. Get Harbor ready to receive pushed images

```bash
kubectl create secret docker-registry harbor-credentials \
  --docker-server="$HARBOR" \
  --docker-username='<ROBOT_USERNAME>' \
  --docker-password='<ROBOT_TOKEN>' \
  -n cicd
```

- Use a limited "robot" account for this, not the main Harbor admin login.
- Keep the account used to push images separate from the one used to pull them at runtime.

### 9. Install Tekton — the automation engine

```bash
kubectl apply -f https://storage.googleapis.com/tekton-releases/pipeline/previous/${TEKTON_VERSION}/release.yaml
kubectl apply -f https://storage.googleapis.com/tekton-releases/triggers/previous/${TRIGGERS_VERSION}/release.yaml
kubectl apply -f https://storage.googleapis.com/tekton-releases/triggers/previous/${TRIGGERS_VERSION}/interceptors.yaml
kubectl apply -f https://storage.googleapis.com/tekton-releases/dashboard/previous/${DASHBOARD_VERSION}/release.yaml

kubectl get pods -n tekton-pipelines
```

### 10. Give the Dashboard a proper web address

So people can check on builds through a browser, the same way they'd check on any other app:

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: tekton-dashboard
  namespace: tekton-pipelines
spec:
  hosts:
    - "tekton.example.internal"
  gateways:
    - istio-system/main-gateway
  http:
    - route:
        - destination:
            host: tekton-dashboard.tekton-pipelines.svc.cluster.local
            port:
              number: 9097
```

`cert-manager` gives this address a valid TLS certificate automatically, and `external-dns`
publishes the DNS record — the same way it already works for application traffic.

### 11. Install Cosign and Syft — signing and the ingredients list

```bash
# cosign — signs images and their SBOMs
curl -LO https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/cosign-linux-amd64
sudo install -m 0755 cosign-linux-amd64 /usr/local/bin/cosign

# syft — generates the SBOM (ingredients list)
curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh \
  | sudo sh -s -- -b /usr/local/bin ${SYFT_VERSION}
```

### 12. Create the signing key

```bash
cosign generate-key-pair k8s://${CI_NS}/cosign-key
```

This stores the private signing key safely inside the cluster as a Secret. Keep the matching
public key (`cosign.pub`) somewhere separate — Harbor uses it to check every image's signature
before allowing it to be pulled.

### 13. Set up the pipeline itself

Tekton now has everything it needs to:

1. Check whether the pushed repo has a `Dockerfile`.
2. Run BuildKit **or** Buildpacks, depending on the answer.
3. Generate the SBOM with Syft.
4. Sign the image and the SBOM with Cosign.
5. Push everything to Harbor.

This logic lives in a small number of Tekton building blocks (called `Task`s), tied together
into one `Pipeline`:

- **`detect-build-type`** — looks for a `Dockerfile` and records the answer.
- **`buildkit-build`** — runs when a `Dockerfile` was found; builds the image, then signs it
  and its SBOM as the final steps in the same Task.
- **`buildpacks-build`** — runs when no `Dockerfile` was found, using `$BUILDER_IMAGE`; builds
  the image, then signs it and its SBOM as the final steps in the same Task.

```yaml
apiVersion: tekton.dev/v1
kind: Task
metadata:
  name: detect-build-type
  namespace: cicd
spec:
  workspaces:
    - name: source
  results:
    - name: build-type
      description: "buildkit or buildpacks"
  steps:
    - name: detect
      image: alpine:3.20
      script: |
        #!/bin/sh
        if [ -f "$(workspaces.source.path)/Dockerfile" ]; then
          echo -n "buildkit" > $(results.build-type.path)
        else
          echo -n "buildpacks" > $(results.build-type.path)
        fi
```

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
  results:
    - name: IMAGE_DIGEST
  steps:
    - name: build
      image: moby/buildkit:latest
      securityContext:
        runAsUser: 1000
        runAsGroup: 1000
        seccompProfile:
          type: Unconfined
      env:
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
        - --metadata-file
        - /tekton/results-md.json
      volumeMounts:
        - name: dockerconfig
          mountPath: /tekton/home/.docker
    - name: write-digest
      image: alpine:3.20
      script: |
        #!/bin/sh
        grep -o '"containerimage.digest":"[^"]*"' /tekton/results-md.json \
          | cut -d'"' -f4 | tr -d '\n' > $(results.IMAGE_DIGEST.path)
    - name: generate-sbom
      image: anchore/syft:latest
      script: |
        #!/bin/sh
        syft "$(params.image)@$(cat $(results.IMAGE_DIGEST.path))" -o spdx-json > /workspace/sbom.spdx.json
    - name: cosign-sign-image
      image: gcr.io/projectsigstore/cosign:v2.4.1
      env:
        - name: COSIGN_PASSWORD
          valueFrom:
            secretKeyRef:
              name: cosign-key
              key: cosign.password
      script: |
        #!/bin/sh
        cosign sign --yes --key k8s://cicd/cosign-key \
          "$(params.image)@$(cat $(results.IMAGE_DIGEST.path))"
    - name: cosign-attest-sbom
      image: gcr.io/projectsigstore/cosign:v2.4.1
      env:
        - name: COSIGN_PASSWORD
          valueFrom:
            secretKeyRef:
              name: cosign-key
              key: cosign.password
      script: |
        #!/bin/sh
        cosign attest --yes --key k8s://cicd/cosign-key \
          --predicate /workspace/sbom.spdx.json \
          --type spdxjson \
          "$(params.image)@$(cat $(results.IMAGE_DIGEST.path))"
  volumes:
    - name: dockerconfig
      secret:
        secretName: harbor-credentials
```

> **Requirement #9 note:** signing and SBOM attestation are steps *inside this same Task*, run
> immediately after `write-digest` — not a separate Task chained afterward. This is
> deliberately more verbose (the same three steps are repeated in `buildpacks-build` below) in
> order to match "incorporate Cosign directly into the Tekton build task" literally.

```yaml
apiVersion: tekton.dev/v1
kind: Task
metadata:
  name: buildpacks-build
  namespace: cicd
spec:
  params:
    - name: image
      type: string
    - name: builder
      type: string
      default: paketobuildpacks/builder-jammy-base
    - name: run-image
      type: string
      default: index.docker.io/paketobuildpacks/run-jammy-base
  workspaces:
    - name: source
  results:
    - name: IMAGE_DIGEST
  steps:
    - name: prepare
      image: $(params.builder)
      securityContext:
        runAsUser: 0
      script: |
        #!/bin/sh
        mkdir -p /layers /cache
        chown -R cnb:cnb /layers /cache "$(workspaces.source.path)"
    - name: create
      image: $(params.builder)
      securityContext:
        runAsUser: 1000
        runAsGroup: 1000
      command: ["/cnb/lifecycle/creator"]
      args:
        - "-app=$(workspaces.source.path)"
        - "-cache-dir=/cache"
        - "-layers=/layers"
        - "-run-image=$(params.run-image)"
        - "-report=/layers/report.toml"
        - "$(params.image)"
      volumeMounts:
        - name: dockerconfig
          mountPath: /tekton/home/.docker
    - name: write-digest
      image: alpine:3.20
      script: |
        #!/bin/sh
        grep '^digest' /layers/report.toml | cut -d'"' -f2 | tr -d '\n' > $(results.IMAGE_DIGEST.path)
    - name: generate-sbom
      image: anchore/syft:latest
      script: |
        #!/bin/sh
        syft "$(params.image)@$(cat $(results.IMAGE_DIGEST.path))" -o spdx-json > /workspace/sbom.spdx.json
    - name: cosign-sign-image
      image: gcr.io/projectsigstore/cosign:v2.4.1
      env:
        - name: COSIGN_PASSWORD
          valueFrom:
            secretKeyRef:
              name: cosign-key
              key: cosign.password
      script: |
        #!/bin/sh
        cosign sign --yes --key k8s://cicd/cosign-key \
          "$(params.image)@$(cat $(results.IMAGE_DIGEST.path))"
    - name: cosign-attest-sbom
      image: gcr.io/projectsigstore/cosign:v2.4.1
      env:
        - name: COSIGN_PASSWORD
          valueFrom:
            secretKeyRef:
              name: cosign-key
              key: cosign.password
      script: |
        #!/bin/sh
        cosign attest --yes --key k8s://cicd/cosign-key \
          --predicate /workspace/sbom.spdx.json \
          --type spdxjson \
          "$(params.image)@$(cat $(results.IMAGE_DIGEST.path))"
  volumes:
    - name: dockerconfig
      secret:
        secretName: harbor-credentials
```

> The `-run-image` value above is set on purpose for clarity, but the builder already knows to
> use `run-jammy-base` on its own — it's baked into the builder's own metadata. Signing and
> SBOM attestation are steps inside this same Task too, for the same reason as `buildkit-build`
> above.

Finally, one `Pipeline` ties the three `Task`s together, using a `when` condition so that only
**one** of `buildkit-build` / `buildpacks-build` runs on any given build — whichever one
matches what `detect-build-type` found. Signing and SBOM attestation happen automatically as
the last steps inside whichever build Task runs — there's no separate signing stage in the
Pipeline itself:

```yaml
apiVersion: tekton.dev/v1
kind: Pipeline
metadata:
  name: app-build-pipeline
  namespace: cicd
spec:
  params:
    - name: repo-url
    - name: revision
      default: main
    - name: image
  workspaces:
    - name: shared-workspace
  tasks:
    - name: fetch-source
      taskRef: { name: git-clone }
      params:
        - { name: url, value: $(params.repo-url) }
        - { name: revision, value: $(params.revision) }
      workspaces: [{ name: output, workspace: shared-workspace }]

    - name: detect-build-type
      taskRef: { name: detect-build-type }
      runAfter: ["fetch-source"]
      workspaces: [{ name: source, workspace: shared-workspace }]

    - name: buildkit-build
      taskRef: { name: buildkit-build }
      runAfter: ["detect-build-type"]
      when:
        - input: "$(tasks.detect-build-type.results.build-type)"
          operator: in
          values: ["buildkit"]
      params: [{ name: image, value: $(params.image) }]
      workspaces: [{ name: source, workspace: shared-workspace }]

    - name: buildpacks-build
      taskRef: { name: buildpacks-build }
      runAfter: ["detect-build-type"]
      when:
        - input: "$(tasks.detect-build-type.results.build-type)"
          operator: in
          values: ["buildpacks"]
      params: [{ name: image, value: $(params.image) }]
      workspaces: [{ name: source, workspace: shared-workspace }]
```

### 14. Run it and check the result

```bash
tkn pipeline start app-build-pipeline -n cicd \
  -p repo-url=https://internal-git.example/team/sample-app.git \
  -p revision=main \
  -p image=${HARBOR}/applications/sample:dev \
  -w name=shared-workspace,claimName=<pvc-name>

tkn pipelinerun logs -f -n cicd

cosign verify --key cosign.pub ${HARBOR}/applications/sample:dev
```

---

## Automatic Triggering — Gitea Webhook → Tekton Triggers (Lab Runbook)

Everything above lets you start the pipeline by hand (`tkn pipeline start`, step 14). This
section makes it **fully automatic**: a `git push` to Gitea fires a webhook, Tekton Triggers
filters it, and a `PipelineRun` starts on its own. It is the working lab runbook for the
TravelPortal application and uses lab-specific names, IPs, and Harbor host values — replace them
with your own environment's values (see the placeholder rule in the Conclusion).

**Prerequisites:** the Tekton Pipelines, Triggers, **and `interceptors.yaml`** installs from
step 9 (the CEL interceptor used below ships in `interceptors.yaml`), the `cicd` namespace, a
Gitea instance, and the Harbor/Cosign setup from steps 8 and 12.

> **How this section relates to the pipeline in step 13 — read before applying.**
> The lab runbook below targets a Pipeline named `travelportal-pipeline-values-update`, which
> is an extended lab variant of the step-13 `app-build-pipeline`. Differences to be aware of:
>
> | Item | Step 13 (`app-build-pipeline`) | Lab runbook (`travelportal-pipeline-values-update`) |
> |---|---|---|
> | Param names | `repo-url`, `revision`, `image` | `REPO_URL`, `REVISION`, `IMAGE`, `BUILDER_IMAGE` |
> | Pipeline task names | `buildkit-build`, `buildpacks-build` | `buildkit`, `buildpack` |
> | Signing | Steps *inside* each build Task | Separate `sign` task (`sign-image`) after the build |
> | Buildpacks digest result | `IMAGE_DIGEST` | `APP_IMAGE_DIGEST`, normalized by `sign` |
> | Workspaces | `shared-workspace` | `source`, `dockerconfig`, `cosign-key` |
> | Harbor push secret | `harbor-credentials` | `harbor-registry-secret` |
> | Extra final stage | none | `update-values` (commits `helm-charts/values.yaml` to Gitea) |
>
> The source runbook gives only fragments of the `sign-image` and `update-values` Tasks and the
> full `travelportal-pipeline-values-update` Pipeline is not reproduced in it, so those
> definitions must already exist in your cluster (the checklist in W24 verifies the Pipeline
> exists). To trigger `app-build-pipeline` instead, the TriggerTemplate's `pipelineRef`, param
> names, and workspace bindings must be changed to match it using the table above.

### W1. Purpose

This document captures the working lab setup for automatically starting the TravelPortal Tekton pipeline when a developer pushes to the Gitea repository.

Lab architecture:

```text
Developer
   |
   | git push origin main
   v
Gitea
10.12.90.62
   |
   | POST webhook
   v
NodePort
10.12.92.3:31877
   |
   v
Tekton EventListener
travelportal-github-listener
   |
   +--> CEL interceptor
   |      |
   |      +--> only main branch
   |      +--> changed-file self-trigger filter
   |
   +--> TriggerBinding
   |
   +--> TriggerTemplate
   |
   v
PipelineRun
   |
   v
travelportal-pipeline-values-update
   |
   +--> clone
   +--> detect
   +--> BuildKit OR Buildpacks
   +--> sign
   +--> update-values
   |
   v
Gitea commit of helm-charts/values.yaml
```

This lab uses Gitea because the lab network is internal and GitHub.com cannot directly reach the VKS NodePort.

> **Reading this runbook:** Every executable command has a short **What / Why / How** note immediately before it. Every YAML block has a matching explanation covering what it defines, why it is needed, and how it connects to the flow. Each explanation is five lines or fewer.

---

### W2. Lab-specific values

#### Kubernetes

Namespace:

```text
cicd
```

Tekton Pipeline:

```text
travelportal-pipeline-values-update
```

EventListener:

```text
travelportal-github-listener
```

EventListener Service:

```text
el-travelportal-github-listener
```

EventListener Service type:

```text
NodePort
```

Webhook port:

```text
8080 -> 31877
```

Node used for webhook testing:

```text
10.12.92.3
```

Webhook URL:

```text
http://10.12.92.3:31877
```

Gitea:

```text
http://10.12.90.62
```

Gitea repository:

```text
http://10.12.90.62/admin/travelPortal-test-buildpack.git
```

Repository branch:

```text
main
```

Gitea namespace:

```text
gitea
```

Gitea Helm release:

```text
gitea
```

Gitea Helm chart:

```text
gitea-charts/gitea
```

Gitea chart version used in the lab:

```text
12.7.0
```

#### Validation status from the lab history

- **Verified working:** Tekton Triggers components, EventListener readiness, NodePort `31877`, Gitea `ALLOWED_HOST_LIST`, direct webhook POST returning `202`, Gitea pushes, and `values.yaml` updates.
- **Verified working after fixes:** BuildKit digest result, sign Task `source` workspace binding, and `update-values` pointing back to Gitea instead of GitHub.
- **Hardened configuration:** the changed-file CEL filter is documented as the final self-trigger safeguard. Its CEL `exists()` pattern is valid CEL syntax, but the lab history did not contain a successful two-case test proving the filter blocks the CI commit.
- **Not recommended as the primary safeguard:** the earlier message-only filter was attempted but was not treated as reliable in this lab.

---

### W3. Tekton Triggers components

The setup uses these Tekton Triggers objects:

```text
ServiceAccount
github-trigger-sa

Role
github-trigger-role

RoleBinding
github-trigger-rolebinding

ClusterRole
github-trigger-cluster-role

ClusterRoleBinding
github-trigger-cluster-rolebinding

EventListener
travelportal-github-listener

TriggerBinding
travelportal-github-binding

TriggerTemplate
travelportal-github-template
```

The EventListener name contains `github`, but the webhook source is now Gitea. The name does not affect functionality.

---

### W4. Tekton Triggers CRDs and controller validation

Check that Triggers is installed:

**What:** Checks that the Tekton Triggers CRDs exist.  
**Why:** EventListener and trigger objects depend on these CRDs.  
**How:** Confirm the expected Triggers resource names appear.

```bash
kubectl get crd | grep triggers.tekton.dev
```

Expected CRDs include:

```text
clusterinterceptors.triggers.tekton.dev
clustertriggerbindings.triggers.tekton.dev
eventlisteners.triggers.tekton.dev
interceptors.triggers.tekton.dev
triggerbindings.triggers.tekton.dev
triggers.triggers.tekton.dev
triggertemplates.triggers.tekton.dev
```

Check the Triggers pods:

**What:** Lists the Tekton system pods.  
**Why:** The Triggers controller, interceptors, and webhook must be running.  
**How:** Look for the expected `tekton-triggers-*` pods.

```bash
kubectl get pods -n tekton-pipelines
```

Expected:

```text
tekton-triggers-controller-...
tekton-triggers-core-interceptors-...
tekton-triggers-webhook-...
```

Check:

**What:** Lists Triggers-related Deployments.  
**Why:** Confirms the controller components were deployed.  
**How:** `grep triggers` keeps the output focused.

```bash
kubectl get deployment -n tekton-pipelines | grep triggers
```

---

### W5. EventListener ServiceAccount and RBAC

The following is a field inside `eventlistener.yaml`, not a separate file:

**What:** Sets the EventListener ServiceAccount field.  
**Why:** The listener needs a specific Kubernetes identity for RBAC.  
**How:** The name must match `github-trigger-sa`.

```yaml
serviceAccountName: github-trigger-sa
```

#### W5.1 ServiceAccount

Save this object in `github-trigger-rbac.yaml`.

**What:** Creates the `github-trigger-sa` ServiceAccount in `cicd`.  
**Why:** Gives the EventListener a dedicated identity.  
**How:** The EventListener references this object by name.

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: github-trigger-sa
  namespace: cicd
```

#### W5.2 Namespace Role

Save the following Role in the same `github-trigger-rbac.yaml` file as the other RBAC objects.

The EventListener needs permission to read the Triggers resources in `cicd` and create PipelineRuns.

**What:** Grants namespace-scoped access to Trigger resources and PipelineRuns.  
**Why:** The EventListener must read trigger configuration and create PipelineRuns.  
**How:** The Role applies only in `cicd`.

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: github-trigger-role
  namespace: cicd
rules:
  - apiGroups: ["triggers.tekton.dev"]
    resources:
      - eventlisteners
      - triggerbindings
      - triggertemplates
      - triggers
      - interceptors
    verbs:
      - get
      - list
      - watch

  - apiGroups: ["tekton.dev"]
    resources:
      - pipelineruns
    verbs:
      - create
      - get
      - list
      - watch
```

#### W5.3 RoleBinding

Save this object in the same `github-trigger-rbac.yaml` file.

**What:** Binds `github-trigger-sa` to `github-trigger-role`.  
**Why:** A Role grants no permissions until a subject is bound.  
**How:** `subjects` names the ServiceAccount and `roleRef` names the Role.

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: github-trigger-rolebinding
  namespace: cicd
subjects:
  - kind: ServiceAccount
    name: github-trigger-sa
    namespace: cicd
roleRef:
  kind: Role
  name: github-trigger-role
  apiGroup: rbac.authorization.k8s.io
```

#### W5.4 ClusterRole

Save this object in the same `github-trigger-rbac.yaml` file.

These Triggers resources are cluster-scoped:

```text
clusterinterceptors
clustertriggerbindings
```

Therefore a ClusterRole is required.

**What:** Grants read access to cluster-scoped Triggers resources.  
**Why:** `clusterinterceptors` and `clustertriggerbindings` are cluster-scoped.  
**How:** Pair it with the ClusterRoleBinding below.

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: github-trigger-cluster-role
rules:
  - apiGroups: ["triggers.tekton.dev"]
    resources:
      - clusterinterceptors
      - clustertriggerbindings
    verbs:
      - get
      - list
      - watch
```

#### W5.5 ClusterRoleBinding

Save this object in the same `github-trigger-rbac.yaml` file.

**What:** Binds `github-trigger-sa` to the cluster-scoped Triggers role.  
**Why:** Without it, cluster-scoped reads can fail with `forbidden`.  
**How:** The ServiceAccount is namespaced but may bind to a ClusterRole.

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: github-trigger-cluster-rolebinding
subjects:
  - kind: ServiceAccount
    name: github-trigger-sa
    namespace: cicd
roleRef:
  kind: ClusterRole
  name: github-trigger-cluster-role
  apiGroup: rbac.authorization.k8s.io
```

Apply all RBAC objects:

**What:** Applies the complete EventListener RBAC file.  
**Why:** The listener needs these permissions to inspect Trigger resources and create PipelineRuns.  
**How:** Keep the five RBAC objects together in this file.

```bash
kubectl apply -f github-trigger-rbac.yaml
```

Validate:

**What:** Verifies the five RBAC objects exist.  
**Why:** A missing object can prevent the EventListener from starting.  
**How:** Confirm each command returns the expected object.

```bash
kubectl get sa github-trigger-sa -n cicd
kubectl get role github-trigger-role -n cicd
kubectl get rolebinding github-trigger-rolebinding -n cicd
kubectl get clusterrole github-trigger-cluster-role
kubectl get clusterrolebinding github-trigger-cluster-rolebinding
```

Validate permissions:

**What:** Tests the listener ServiceAccount permissions directly.  
**Why:** `yes` proves the RBAC is effective, not just present.  
**How:** Every requested permission should return `yes`.

```bash
kubectl auth can-i list triggerbindings.triggers.tekton.dev \
  --as=system:serviceaccount:cicd:github-trigger-sa \
  -n cicd

kubectl auth can-i list triggertemplates.triggers.tekton.dev \
  --as=system:serviceaccount:cicd:github-trigger-sa \
  -n cicd

kubectl auth can-i list eventlisteners.triggers.tekton.dev \
  --as=system:serviceaccount:cicd:github-trigger-sa \
  -n cicd

kubectl auth can-i list clusterinterceptors.triggers.tekton.dev \
  --as=system:serviceaccount:cicd:github-trigger-sa

kubectl auth can-i list clustertriggerbindings.triggers.tekton.dev \
  --as=system:serviceaccount:cicd:github-trigger-sa

kubectl auth can-i create pipelineruns.tekton.dev \
  --as=system:serviceaccount:cicd:github-trigger-sa \
  -n cicd
```

Expected result for all above:

```text
yes
```

Do NOT grant `pods:create` to this ServiceAccount just because an earlier check returned `no`. The Deployment/ReplicaSet controller creates the EventListener pod. The EventListener ServiceAccount needs permissions for Trigger resources and the resources it instantiates.

---

### W6. Gitea outbound webhook security

Gitea originally rejected the NodePort with:

```text
webhook can only call allowed HTTP servers
(check your security.ALLOWED_HOST_LIST setting)
```

The Gitea deployment is Helm-managed.

Release:

```text
gitea
```

Chart:

```text
gitea-charts/gitea
```

Version:

```text
12.7.0
```

#### W6.1 Working Helm override

Use `additionalConfigFromEnvs`:

**What:** Defines the Gitea Helm override for outbound webhook hosts.  
**Why:** Gitea must allow the Tekton NodePort IP.  
**How:** The chart maps the environment variable into `[security] ALLOWED_HOST_LIST`.

```yaml
gitea:
  additionalConfigFromEnvs:
    - name: GITEA__SECURITY__ALLOWED_HOST_LIST
      value: "10.12.90.62,10.12.92.3"
```

Create:

**What:** Creates the temporary Gitea Helm override file.  
**Why:** The chart must render the outbound webhook allow-list into `app.ini`.  
**How:** Keep the two lab IPs exactly as shown.

```bash
cat >/tmp/gitea-webhook-values.yaml <<'EOF'
gitea:
  additionalConfigFromEnvs:
    - name: GITEA__SECURITY__ALLOWED_HOST_LIST
      value: "10.12.90.62,10.12.92.3"
EOF
```

Use `--reuse-values` so existing Helm values are preserved:

**What:** Applies the Gitea Helm override to the existing release.  
**Why:** Gitea must permit calls to the Tekton NodePort.  
**How:** `--reuse-values` preserves the existing release values.

```bash
helm upgrade gitea gitea-charts/gitea \
  -n gitea \
  --version 12.7.0 \
  --reuse-values \
  -f /tmp/gitea-webhook-values.yaml
```

Validate:

**What:** Waits for the Gitea rollout to finish.  
**Why:** Validate the setting only after the new pod is ready.  
**How:** A successful command means the Deployment completed its rollout.

```bash
kubectl rollout status deployment/gitea -n gitea
```

Then:

**What:** Reads the live Gitea `app.ini` security section.  
**Why:** Confirms the Helm setting reached the running container.  
**How:** Check for the expected `ALLOWED_HOST_LIST` value.

```bash
kubectl exec -n gitea deployment/gitea -- \
  grep -n -A10 '^\[security\]' /data/gitea/conf/app.ini
```

Expected:

```text
[security]
...
ALLOWED_HOST_LIST = 10.12.90.62,10.12.92.3
```

A prior attempt stored `gitea.config.security.ALLOWED_HOST_LIST` in Helm values but did not render the value into `app.ini`; the `additionalConfigFromEnvs` approach rendered the setting correctly.

---

### W7. TriggerBinding

The TriggerBinding extracts information from the Gitea JSON payload.

For this lab the repository URL is fixed, which is intentional. This prevents differences between GitHub/Gitea payload field names from affecting the repository parameter.

**What:** Maps Gitea payload fields into named trigger parameters.  
**Why:** The TriggerTemplate needs the repository, branch, message, and SHA fields.  
**How:** `$(body...)` is evaluated against the incoming event.

```yaml
apiVersion: triggers.tekton.dev/v1beta1
kind: TriggerBinding
metadata:
  name: travelportal-github-binding
  namespace: cicd
spec:
  params:
    - name: REPO_URL
      value: http://10.12.90.62/admin/travelPortal-test-buildpack.git

    - name: REVISION
      value: main

    - name: COMMIT_MESSAGE
      value: $(body.head_commit.message)

    - name: COMMIT_SHA
      value: $(body.after)
```

Apply:

**What:** Creates or updates the TriggerBinding.  
**Why:** It maps incoming Gitea fields into named trigger parameters.  
**How:** Apply it before the EventListener references it.

```bash
kubectl apply -f triggerbinding.yaml
```

Validate:

**What:** Shows the live TriggerBinding object.  
**Why:** Confirms the repository URL and branch mapping.  
**How:** Compare `REPO_URL` with Gitea and `REVISION` with `main`.

```bash
kubectl get triggerbinding travelportal-github-binding -n cicd -o yaml
```

The important values must be:

```text
REPO_URL = http://10.12.90.62/admin/travelPortal-test-buildpack.git
REVISION = main
```

---

### W8. TriggerTemplate

Save the following object as `triggertemplate.yaml`.

The TriggerTemplate creates the PipelineRun.

Working structure:

**What:** Defines the PipelineRun created by an accepted webhook.  
**Why:** It separates event parsing from Pipeline execution configuration.  
**How:** `pipelineRef`, params, TaskRun settings, and workspaces define the run.

```yaml
apiVersion: triggers.tekton.dev/v1beta1
kind: TriggerTemplate
metadata:
  name: travelportal-github-template
  namespace: cicd
spec:
  params:
    - name: REPO_URL
      description: Git repository URL

    - name: REVISION
      description: Git branch
      default: main

    - name: COMMIT_MESSAGE
      description: Git commit message
      default: Gitea push - TravelPortal build

    - name: COMMIT_SHA
      description: Git commit SHA

  resourcetemplates:
    - apiVersion: tekton.dev/v1
      kind: PipelineRun
      metadata:
        generateName: travelportal-build-
      spec:
        pipelineRef:
          name: travelportal-pipeline-values-update

        params:
          - name: REPO_URL
            value: $(tt.params.REPO_URL)

          - name: REVISION
            value: $(tt.params.REVISION)

          - name: IMAGE
            value: lab25-harbor.lab25.sunfire.lab/cicd/travelportal:latest

          - name: BUILDER_IMAGE
            value: paketobuildpacks/builder-jammy-base

        taskRunTemplate:
          serviceAccountName: default

        taskRunSpecs:
          - pipelineTaskName: buildkit
            podTemplate:
              volumes:
                - name: harbor-ca
                  configMap:
                    name: harbor-ca-cert

        timeouts:
          pipeline: 1h0m0s

        workspaces:
          - name: source
            persistentVolumeClaim:
              claimName: buildpacks-source-pvc

          - name: dockerconfig
            secret:
              secretName: harbor-registry-secret

          - name: cosign-key
            secret:
              secretName: cosign-key
```

Apply:

**What:** Creates or updates the TriggerTemplate.  
**Why:** It defines the PipelineRun generated by an accepted webhook.  
**How:** Apply after the referenced Pipeline and workspaces exist.

```bash
kubectl apply -f triggertemplate.yaml
```

Validate:

**What:** Shows the live TriggerTemplate.  
**Why:** Confirms the PipelineRun parameters and workspace bindings.  
**How:** Inspect `pipelineRef`, params, `taskRunSpecs`, and workspaces.

```bash
kubectl get triggertemplate travelportal-github-template -n cicd -o yaml
```

The PipelineRun must reference:

```text
travelportal-pipeline-values-update
```

and pass the Gitea repository:

```text
http://10.12.90.62/admin/travelPortal-test-buildpack.git
```

---

### W9. EventListener

Save the following object as `eventlistener.yaml`.

The current EventListener intentionally retains its historical name `travelportal-github-listener`, but it is used by Gitea. The NodePort wiring was verified in the lab; the changed-file CEL filter below is the hardened configuration and should be validated with both developer and CI commits.

#### Final NodePort configuration (hardened)

**What:** Defines the HTTP EventListener and trigger chain.  
**Why:** Gitea needs a reachable endpoint that can filter and launch a PipelineRun.  
**How:** NodePort exposes it; CEL filters changed files; Binding and Template create the run.

```yaml
apiVersion: triggers.tekton.dev/v1beta1
kind: EventListener
metadata:
  name: travelportal-github-listener
  namespace: cicd
spec:
  serviceAccountName: github-trigger-sa

  resources:
    kubernetesResource:
      serviceType: NodePort

  triggers:
    - name: travelportal-push

      interceptors:
        - ref:
            apiVersion: triggers.tekton.dev
            kind: ClusterInterceptor
            name: cel
          params:
            - name: filter
              value: >-
                body.ref == 'refs/heads/main' &&
                body.commits.exists(c,
                  c.added.exists(f, f != 'helm-charts/values.yaml') ||
                  c.modified.exists(f, f != 'helm-charts/values.yaml') ||
                  c.removed.exists(f, f != 'helm-charts/values.yaml')
                )

      bindings:
        - ref: travelportal-github-binding

      template:
        ref: travelportal-github-template
```

Apply:

**What:** Creates or updates the EventListener.  
**Why:** It is the HTTP entry point for the Gitea webhook.  
**How:** It ties NodePort, CEL, Binding, and Template together.

```bash
kubectl apply -f eventlistener.yaml
```

Validate:

**What:** Checks EventListener readiness.  
**Why:** Gitea needs a ready listener before webhook delivery can work.  
**How:** Look for `AVAILABLE=True` and `READY=True`.

```bash
kubectl get eventlistener travelportal-github-listener -n cicd
```

Expected:

```text
AVAILABLE=True
READY=True
```

Check the generated Service:

**What:** Shows the EventListener Service and actual NodePort.  
**Why:** The live Service is authoritative if the port changes.  
**How:** Use the `8080:<nodePort>` mapping for Gitea.

```bash
kubectl get svc el-travelportal-github-listener -n cicd
```

Working lab result:

```text
TYPE: NodePort
8080:31877/TCP
9000:32312/TCP
```

The webhook must use the application port:

```text
8080
```

therefore:

```text
http://10.12.92.3:31877
```

Do not use:

```text
32312
```

for the webhook.

---

### W10. EventListener connectivity validation

First validate the Service endpoints:

**What:** Checks that the Service has a live EventListener backend.  
**Why:** A NodePort without an endpoint cannot deliver the request.  
**How:** Confirm an endpoint is exposed on port `8080`.

```bash
kubectl get endpoints el-travelportal-github-listener -n cicd -o wide
```

Expected to contain the EventListener pod on:

```text
:8080
```

Check the pod:

**What:** Finds the EventListener pod and its node.  
**Why:** Helps distinguish pod placement from Service/network issues.  
**How:** The label selects only the EventListener pods.

```bash
kubectl get pods -n cicd \
  -l eventlistener=travelportal-github-listener \
  -o wide
```

Test the NodePort:

**What:** Sends a basic request to the EventListener NodePort.  
**Why:** Separates network reachability from webhook delivery issues.  
**How:** Any HTTP response is useful; `Connection refused` means the endpoint is not reachable.

```bash
curl -v http://10.12.92.3:31877
```

A direct webhook-style POST test:

**What:** Creates a repeatable push-event JSON payload.  
**Why:** It lets you test Tekton without making a real repository commit.  
**How:** The payload includes `commits[]` so it matches the final file-change CEL filter.

```bash
cat >/tmp/test-event.json <<'EOF'
{
  "ref": "refs/heads/main",
  "after": "test-sha",
  "head_commit": {
    "message": "test webhook"
  },
  "commits": [
    {
      "added": [],
      "modified": ["Dockerfile"],
      "removed": []
    }
  ]
}
EOF
```

Then:

**What:** Posts the test payload to the EventListener as JSON.  
**Why:** Confirms Tekton accepts the webhook before testing Gitea delivery.  
**How:** Expect `HTTP/1.1 202 Accepted` when the request is accepted.

```bash
curl -v \
  -H 'Content-Type: application/json' \
  --data-binary @/tmp/test-event.json \
  http://10.12.92.3:31877
```

A working EventListener returned:

```text
HTTP/1.1 202 Accepted
```

with a Tekton event ID.

This proves:

```text
jumpbox -> NodePort -> EventListener
```

is working.

---

### W11. Gitea repository webhook

Repository:

```text
admin/travelPortal-test-buildpack
```

Open:

```text
Gitea
  -> Repository
  -> Settings
  -> Webhooks
  -> Add Webhook
```

Select Gitea webhook.

Use:

```text
Target URL:
http://10.12.92.3:31877
```

Method:

```text
POST
```

Content type:

```text
application/json
```

Event:

```text
Push events
```

Branch:

```text
main
```

Save the webhook.

After saving, use:

```text
Test Delivery
```

or push a real commit.

Gitea also supports a webhook branch filter; configure it as `main` so the webhook itself only delivers pushes for the lab branch. Tekton still keeps its own `refs/heads/main` CEL check as a second control.

---

### W12. Expected Gitea webhook payload

A working Gitea payload in this lab looked like:

```json
{
  "ref": "refs/heads/main",
  "before": "896090104022605df91278e8ad042060d3ac0d39",
  "after": "1a663ee511d1b830db84b844db871dc77cc7569e",
  "head_commit": {
    "id": "1a663ee511d1b830db84b844db871dc77cc7569e",
    "message": "df\n"
  },
  "repository": {
    "full_name": "admin/travelPortal-test-buildpack",
    "clone_url": "http://10.12.90.62/admin/travelPortal-test-buildpack.git",
    "default_branch": "main"
  },
  "commits": [
    {
      "added": [],
      "modified": ["Dockerfile"],
      "removed": []
    }
  ]
}
```

For the final setup, the important payload values are:

```text
body.ref
body.after
body.head_commit.message
```

The webhook also provided Gitea/GitHub-compatible headers such as:

```text
X-Gitea-Event: push
X-Gitea-Signature: ...
X-GitHub-Event: push
X-Hub-Signature-256: ...
```

The EventListener does not need the GitHub interceptor for this Gitea setup.

---

### W13. Pipeline behavior after a developer push

Developer:

**What:** Creates and pushes a real developer commit.  
**Why:** Exercises the complete Gitea-to-Tekton trigger path.  
**How:** Run from the TravelPortal repository on branch `main`.

```bash
git add .
git commit -m "fix application"
git push origin main
```

Trigger flow:

```text
Gitea
  |
  | POST / 
  v
EventListener :31877
  |
  v
CEL interceptor
  |
  | main branch + changed-file filter
  v
TriggerBinding
  |
  v
TriggerTemplate
  |
  v
PipelineRun travelportal-build-xxxxx
```

Validate:

**What:** Lists PipelineRuns in `cicd`.  
**Why:** Confirms whether a webhook created `travelportal-build-*`.  
**How:** Run after a test delivery or developer push.

```bash
kubectl get pipelineruns -n cicd
```

Watch live:

**What:** Watches PipelineRuns live.  
**Why:** Shows whether the trigger created a run and how it finishes.  
**How:** Stop with `Ctrl+C` after the run reaches a terminal state.

```bash
kubectl get pipelineruns -n cicd -w
```

---

### W14. Pipeline flow

Pipeline:

```text
travelportal-pipeline-values-update
```

Current logical flow:

```text
clone
  |
  v
detect
  |
  +---- Dockerfile present ----> buildkit
  |
  +---- Dockerfile absent -----> buildpack
                         |
                         v
                       sign
                         |
                         v
                    update-values
```

Build type detection:

```text
Dockerfile exists
    -> BUILD_TYPE=buildkit

Dockerfile does not exist
    -> BUILD_TYPE=buildpack
```

Only one build task executes because the Pipeline uses `when` expressions.

---

### W15. BuildKit digest result

BuildKit writes its image digest as a Tekton result:

```text
/tekton/results/IMAGE_DIGEST
```

and also writes a common digest file:

```text
/workspace/source/image-digest
```

Example:

```text
sha256:8af9d23a2ec5a5c3f319ef7ed62ecd413466919a8532e1d1185552fbb9b30a11
```

The working BuildKit metadata extraction used whitespace-tolerant matching:

**What:** Extracts `containerimage.digest` from BuildKit metadata and writes it to the Tekton result and shared digest file.  
**Why:** The earlier JSON parser pattern failed when whitespace appeared around the metadata colon.  
**How:** The expression allows optional whitespace before the colon and captures the quoted digest.

```bash
IMAGE_DIGEST=$(grep '"containerimage.digest"' /tmp/build-metadata.json \
  | sed 's/.*"containerimage.digest"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
printf '%s' "${IMAGE_DIGEST}" > "$(results.IMAGE_DIGEST.path)"
printf '%s' "${IMAGE_DIGEST}" > "/workspace/source/image-digest"
```

The digest is passed to the signing/update stages through the Tekton result.

---

### W16. Buildpacks digest result

The Buildpacks task reads:

```text
/layers/report.toml
```

and writes:

```text
$(results.APP_IMAGE_DIGEST.path)
```

The digest must be exposed as the Buildpacks Task result.

The Pipeline should make the signing/update stage consume one normalized digest from whichever build task actually ran.

The critical hand-off from the working setup is:

**What:** Shows the `sign` Pipeline task binding and normalized result contract.  
**Why:** BuildKit and Buildpacks expose different result names, so `update-values` must not depend directly on only the BuildKit result.  
**How:** `sign` reads the shared `source` workspace and exposes `IMAGE_DIGEST`; `update-values` consumes that result.

```yaml
- name: sign
  params:
    - name: IMAGE
      value: $(params.IMAGE)
  runAfter:
    - buildkit
    - buildpack
  taskRef:
    name: sign-image
  workspaces:
    - name: dockerconfig
      workspace: dockerconfig
    - name: cosign
      workspace: cosign-key
    - name: source
      workspace: source
```

The `update-values` Pipeline task must use:

**What:** Shows the result reference passed to `update-values`.  
**Why:** `$(tasks.buildkit.results.IMAGE_DIGEST)` is unavailable on a Buildpacks run.  
**How:** Read the normalized result from `sign` instead.

```yaml
value: $(tasks.sign.results.IMAGE_DIGEST)
```

Do not reference only:

```text
$(tasks.buildkit.results.IMAGE_DIGEST)
```

because that result does not exist when the Buildpacks branch is used.

The current working pattern is:

```text
BuildKit    -> IMAGE_DIGEST
Buildpacks  -> APP_IMAGE_DIGEST
```

and the signing/update design should normalize those into the same downstream value.

---

### W17. Sign stage

The signing Task runs after either BuildKit or Buildpacks.

The sign stage consumes the normalized image digest, produces the signing/attestation outputs configured in the Task, and signs the image with Cosign.

Required secret/workspace names recorded during the working lab include:

```text
cosign-key
harbor-registry-secret
```

Use the exact secret names required by the current `sign-image` Task; do not assume unrelated credentials are required just from this runbook.

The sign Task must have every workspace that it references.

For example, if the `sign-image` Task reads:

```text
$(workspaces.source.path)/image-digest
```

then the `sign` Pipeline task must explicitly bind that Task workspace:

**What:** Binds the sign Task workspace `source` to the Pipeline source workspace.  
**Why:** The sign step reads the normalized digest file from that workspace.  
**How:** The Task and Pipeline workspace names must match exactly.

```yaml
- name: source
  workspace: source
```

A previous failure was:

```text
declared workspace "source" is required but has not been bound
```

The final Pipeline included the `source` workspace for the sign Task.

---

### W18. Update-values Task

The update task:

```text
update-values
```

does the following:

```text
clone repository
  |
  v
read helm-charts/values.yaml
  |
  v
set image.repository
set image.tag
set image.digest
  |
  v
git commit
  |
  v
git push
```

The correct Gitea repository is:

```text
http://10.12.90.62/admin/travelPortal-test-buildpack.git
```

#### Git credentials

Create a dedicated Gitea token and Kubernetes Secret:

**What:** Creates the Kubernetes Secret used for Gitea writes.  
**Why:** The update-values Task needs repository write credentials.  
**How:** Replace `<GITEA_TOKEN>` with a Gitea Personal Access Token.

```bash
kubectl create secret generic gitea-git-credentials \
  -n cicd \
  --from-literal=username=admin \
  --from-literal=token='<GITEA_TOKEN>'
```

Do not put the token directly in Pipeline YAML. This shell command can also place the token in shell history; use a safer secret-entry method when the lab environment permits it.

In the `update-values` Task definition, use the following environment block to read the Gitea Secret:

**What:** Reads the Gitea username and token from a Kubernetes Secret.  
**Why:** `update-values` needs write access without embedding the token in YAML.  
**How:** The Secret keys must be named `username` and `token`.

```yaml
env:
  - name: GIT_USERNAME
    valueFrom:
      secretKeyRef:
        name: gitea-git-credentials
        key: username

  - name: GIT_TOKEN
    valueFrom:
      secretKeyRef:
        name: gitea-git-credentials
        key: token
```

#### Gitea remote

Do not hard-code GitHub.

Use the Pipeline parameter:

**What:** Sets the authenticated Git remote from the Pipeline parameter.  
**Why:** Prevents CI from pushing to the old GitHub URL.  
**How:** Strip the scheme, then build the internal Gitea remote.

```bash
REPO_URL="$(params.REPO_URL)"
REPO_WITHOUT_SCHEME="${REPO_URL#http://}"
REPO_WITHOUT_SCHEME="${REPO_WITHOUT_SCHEME#https://}"

git remote set-url origin \
  "http://${GIT_USERNAME}:${GIT_TOKEN}@${REPO_WITHOUT_SCHEME}"
```

This produces a Gitea remote based on:

```text
$(params.REPO_URL)
```

which in this lab is:

```text
http://10.12.90.62/admin/travelPortal-test-buildpack.git
```

---

### W19. Git non-fast-forward handling

A CI push can fail with:

```text
! [rejected] main -> main (fetch first)
Updates were rejected because the remote contains work that you do not have locally.
```

This happens when another commit reached Gitea after the Task cloned the repository.

Do NOT solve this with a force-push from the CI workspace:

**What:** Shows the unsafe force-push option only as a warning.  
**Why:** Force-pushing can overwrite newer developer commits.  
**How:** Do not use it for this pipeline; use the fetch/reset recovery.

```bash
git push --force
```

For a safer implementation:

**What:** Fetches the latest remote `main` and aligns the disposable CI clone with it.  
**Why:** Prevents non-fast-forward failures.  
**How:** Reapply the intended `values.yaml` edit after the reset, then commit and push.

```bash
git fetch origin main
git reset --hard origin/main
```

then re-apply the `values.yaml` change, commit, and push.

This safer recovery path is intended for the disposable CI clone; do not run `git reset --hard` on a developer working tree that contains uncommitted work.

---

### W20. The CI feedback loop problem

Without a filter, the system becomes:

```text
Developer
  |
  v
Gitea push
  |
  v
Tekton Pipeline
  |
  v
update-values
  |
  v
CI pushes values.yaml
  |
  v
Gitea webhook
  |
  v
Tekton Pipeline AGAIN
```

This must be prevented.

---

### W21. Self-trigger prevention

The final EventListener uses the changed-file list from the Gitea payload rather than relying only on the commit message.

The CI `update-values` commit should change only:

```text
helm-charts/values.yaml
```

The final filter rejects pushes where every added/modified/removed file is exactly that file.

This is important because a message-only filter was attempted during the lab but was not treated as verified; the file-based rule is the documented final configuration and must be validated with a real Gitea delivery.

---

### W22. Optional message-based defense in depth

You may also give the CI commit a fixed prefix:


**What:** Creates the standard CI-generated commit message.  
**Why:** It provides an optional second self-trigger signal.  
**How:** Keep the prefix exact if the message condition is enabled.

```bash
git commit -m "ci: update TravelPortal image digest"
```

Optional CEL condition:


**What:** Defines the optional message-prefix CEL self-trigger check.  
**Why:** It can reject the CI commit as a second safeguard.  
**How:** Use the exact prefix configured in `update-values`.

```yaml
interceptors:
  - ref:
      apiVersion: triggers.tekton.dev
      kind: ClusterInterceptor
      name: cel
    params:
      - name: filter
        value: >-
          !body.head_commit.message.startsWith('ci: update TravelPortal image digest')
```

Do not use this message-only rule as the sole safeguard for this lab, because it was not empirically verified as sufficient during setup.

#### Final file-change filter used by this runbook


**What:** Defines the file-change CEL filter used by the final EventListener.  
**Why:** It rejects pushes that only change `helm-charts/values.yaml`.  
**How:** Gitea supplies `added`, `modified`, and `removed` arrays for the expression.

```yaml
interceptors:
  - ref:
      apiVersion: triggers.tekton.dev
      kind: ClusterInterceptor
      name: cel
    params:
      - name: filter
        value: >-
          body.ref == 'refs/heads/main' &&
          body.commits.exists(c,
            c.added.exists(f, f != 'helm-charts/values.yaml') ||
            c.modified.exists(f, f != 'helm-charts/values.yaml') ||
            c.removed.exists(f, f != 'helm-charts/values.yaml')
          )
```

**Important:** A developer push that changes only `helm-charts/values.yaml` will also be filtered out. Keep that trade-off in mind if developers are expected to edit that file directly.

Validate the filter with both cases: a developer commit that modifies `Dockerfile` or application code, and the CI commit that modifies only `helm-charts/values.yaml`.

##### Two-case acceptance test

**What:** Watches the latest PipelineRun names while you exercise both event types.  
**Why:** You need to prove that the developer event triggers once and the CI values-only event does not trigger again.  
**How:** Run this before the developer push and keep it running until the `update-values` commit finishes.

```bash
kubectl get pipelineruns -n cicd -w
```

First make a developer change outside `helm-charts/values.yaml` and push it to `main`; exactly one new `travelportal-build-*` run should appear.

Then let `update-values` push its CI commit. The webhook delivery should be visible in Gitea, but no second `travelportal-build-*` PipelineRun should appear for that values-only commit.

If a second PipelineRun appears, inspect the EventListener logs and the actual Gitea payload before changing the CEL expression.

---

### W23. `.gitignore` is NOT the solution

Do not add:

```text
helm-charts/values.yaml
```

to `.gitignore`.

The file is already tracked by Git.

`.gitignore` does not prevent changes to an already-tracked file from being committed.

The feedback loop must be controlled at the trigger/filter level.

---

### W24. End-to-end validation checklist

#### Triggers installed

**What:** Checks that the Tekton Triggers CRDs exist.  
**Why:** EventListener and trigger objects depend on these CRDs.  
**How:** Confirm the expected Triggers resource names appear.

```bash
kubectl get crd | grep triggers.tekton.dev
```

#### Trigger controller healthy

**What:** Runs the check or change shown below.  
**Why:** It validates or applies the configuration in this section.  
**How:** Run it from a machine with the required Kubernetes, Helm, or Git access.

```bash
kubectl get pods -n tekton-pipelines | grep triggers
```

#### ServiceAccount

**What:** Runs the check or change shown below.  
**Why:** It validates or applies the configuration in this section.  
**How:** Run it from a machine with the required Kubernetes, Helm, or Git access.

```bash
kubectl get sa github-trigger-sa -n cicd
```

#### RBAC

**What:** Runs the check or change shown below.  
**Why:** It validates or applies the configuration in this section.  
**How:** Run it from a machine with the required Kubernetes, Helm, or Git access.

```bash
kubectl get role github-trigger-role -n cicd
kubectl get rolebinding github-trigger-rolebinding -n cicd
kubectl get clusterrole github-trigger-cluster-role
kubectl get clusterrolebinding github-trigger-cluster-rolebinding
```

#### EventListener

**What:** Checks EventListener readiness.  
**Why:** Gitea needs a ready listener before webhook delivery can work.  
**How:** Look for `AVAILABLE=True` and `READY=True`.

```bash
kubectl get eventlistener travelportal-github-listener -n cicd
```

Expected:

```text
AVAILABLE=True
READY=True
```

#### NodePort

**What:** Shows the EventListener Service and actual NodePort.  
**Why:** The live Service is authoritative if the port changes.  
**How:** Use the `8080:<nodePort>` mapping for Gitea.

```bash
kubectl get svc el-travelportal-github-listener -n cicd
```

Expected:

```text
8080:31877/TCP
```

#### Endpoint

**What:** Checks that the Service has a live EventListener backend.  
**Why:** A NodePort without an endpoint cannot deliver the request.  
**How:** Confirm an endpoint is exposed on port `8080`.

```bash
kubectl get endpoints el-travelportal-github-listener -n cicd
```

Expected an endpoint on:

```text
:8080
```

#### Direct webhook test

**What:** Posts the test payload to the EventListener as JSON.  
**Why:** Confirms Tekton accepts the webhook before testing Gitea delivery.  
**How:** Expect `HTTP/1.1 202 Accepted` when the request is accepted.

```bash
curl -v \
  -H 'Content-Type: application/json' \
  --data-binary @/tmp/test-event.json \
  http://10.12.92.3:31877
```

Expected:

```text
HTTP/1.1 202 Accepted
```

#### TriggerBinding

**What:** Shows the live TriggerBinding object.  
**Why:** Confirms the repository URL and branch mapping.  
**How:** Compare `REPO_URL` with Gitea and `REVISION` with `main`.

```bash
kubectl get triggerbinding travelportal-github-binding -n cicd
```

#### TriggerTemplate

**What:** Shows the live TriggerTemplate.  
**Why:** Confirms the PipelineRun parameters and workspace bindings.  
**How:** Inspect `pipelineRef`, params, `taskRunSpecs`, and workspaces.

```bash
kubectl get triggertemplate travelportal-github-template -n cicd
```

#### Pipeline exists

**What:** Runs the check or change shown below.  
**Why:** It validates or applies the configuration in this section.  
**How:** Run it from a machine with the required Kubernetes, Helm, or Git access.

```bash
kubectl get pipeline travelportal-pipeline-values-update -n cicd
```

#### Gitea outbound allow-list

**What:** Reads the live Gitea `app.ini` security section.  
**Why:** Confirms the Helm setting reached the running container.  
**How:** Check for the expected `ALLOWED_HOST_LIST` value.

```bash
kubectl exec -n gitea deployment/gitea -- \
  grep -n 'ALLOWED_HOST_LIST' /data/gitea/conf/app.ini
```

Expected:

```text
ALLOWED_HOST_LIST = 10.12.90.62,10.12.92.3
```

#### Gitea webhook

Gitea:

```text
Repository
  -> Settings
  -> Webhooks
```

Target:

```text
http://10.12.92.3:31877
```

#### Watch the EventListener

**What:** Follows EventListener logs in real time.  
**Why:** Shows webhook receipt, CEL filtering, and trigger errors.  
**How:** Start it before a Test Delivery and stop with `Ctrl+C`.

```bash
kubectl logs -f deployment/el-travelportal-github-listener -n cicd
```

#### Watch PipelineRuns

**What:** Watches PipelineRuns live.  
**Why:** Shows whether the trigger created a run and how it finishes.  
**How:** Stop with `Ctrl+C` after the run reaches a terminal state.

```bash
kubectl get pipelineruns -n cicd -w
```

---

### W25. Failure troubleshooting matrix

#### Error: ServiceAccount not found

Example:

```text
serviceaccount "github-trigger-sa" not found
```

Check:

**What:** Runs the check or change shown below.  
**Why:** It validates or applies the configuration in this section.  
**How:** Run it from a machine with the required Kubernetes, Helm, or Git access.

```bash
kubectl get sa github-trigger-sa -n cicd
```

Create/apply the ServiceAccount.

---

#### Error: Trigger resources forbidden

Example:

```text
github-trigger-sa cannot list triggertemplates
```

Fix the Role and ClusterRole permissions.

Validate:

**What:** Tests the listener ServiceAccount permissions directly.  
**Why:** `yes` proves the RBAC is effective, not just present.  
**How:** Every requested permission should return `yes`.

```bash
kubectl auth can-i list triggertemplates.triggers.tekton.dev \
  --as=system:serviceaccount:cicd:github-trigger-sa \
  -n cicd
```

---

#### Error: webhook can only call allowed HTTP servers

Example:

```text
webhook can only call allowed HTTP servers
```

Fix Gitea:

```text
GITEA__SECURITY__ALLOWED_HOST_LIST
```

and include:

```text
10.12.92.3
```

---

#### Error: wrong NodePort

Example:

```text
Connection refused
```

Check:

**What:** Shows the EventListener Service and actual NodePort.  
**Why:** The live Service is authoritative if the port changes.  
**How:** Use the `8080:<nodePort>` mapping for Gitea.

```bash
kubectl get svc el-travelportal-github-listener -n cicd
```

The lab's working mapping was:

```text
8080:31877/TCP
```

Do not use an old/incorrect port such as `31878`.

---

#### EventListener returns 202 but no PipelineRun

Check:

**What:** Reads the EventListener logs once.  
**Why:** Useful when Gitea returns `202` but no PipelineRun appears.  
**How:** Look for interceptor, binding, template, or permission errors.

```bash
kubectl logs deployment/el-travelportal-github-listener -n cicd
```

Then inspect:

**What:** Shows the live TriggerBinding object.  
**Why:** Confirms the repository URL and branch mapping.  
**How:** Compare `REPO_URL` with Gitea and `REVISION` with `main`.

```bash
kubectl get triggerbinding travelportal-github-binding -n cicd -o yaml
kubectl get triggertemplate travelportal-github-template -n cicd -o yaml
kubectl get eventlistener travelportal-github-listener -n cicd -o yaml
```

Check the CEL filter against the actual Gitea payload.

---

#### Gitea webhook Response = 0

If Gitea shows:

```text
Response 0
```

look at the response body.

For example:

```text
webhook can only call allowed HTTP servers
```

means Gitea blocked the request before sending it.

A direct `curl` from the lab is useful to separate:

```text
network/NodePort
```

from:

```text
Gitea webhook security
```

---

#### Pipeline update-values push fails with fetch first

Use:

**What:** Fetches the latest remote `main` and aligns the disposable CI clone with it.  
**Why:** Prevents non-fast-forward failures.  
**How:** Reapply the intended `values.yaml` edit after the reset, then commit and push.

```bash
git fetch origin main
git reset --hard origin/main
```

then reapply the values change and commit.

Do not force push.

---

### W26. Final documented architecture

```text
                           LAB NETWORK
                           ===========

+-------------------+
| Developer         |
| git push          |
+---------+---------+
          |
          v
+-------------------+
| Gitea             |
| 10.12.90.62       |
|                   |
| admin/            |
| travelPortal-     |
| test-buildpack    |
+---------+---------+
          |
          | HTTP POST webhook
          | ALLOWED_HOST_LIST permits
          v
+---------------------------+
| Kubernetes Node            |
| 10.12.92.3:31877           |
|                            |
| NodePort                   |
+-------------+--------------+
              |
              v
+---------------------------+
| Tekton EventListener      |
| travelportal-github-      |
| listener                  |
+-------------+-------------+
              |
              v
+---------------------------+
| CEL interceptor           |
| refs/heads/main           |
| self-trigger protection   |
+-------------+-------------+
              |
              v
+---------------------------+
| TriggerBinding            |
| REPO_URL                  |
| REVISION                  |
| COMMIT_MESSAGE            |
| COMMIT_SHA                |
+-------------+-------------+
              |
              v
+---------------------------+
| TriggerTemplate           |
| creates PipelineRun       |
+-------------+-------------+
              |
              v
+---------------------------+
| travelportal-pipeline-    |
| values-update             |
+-------------+-------------+
              |
       +------+------+
       |             |
       v             v
  Dockerfile      No Dockerfile
       |             |
       v             v
   BuildKit      Buildpacks
       |             |
       +------+------+
              |
              v
          Image Digest
              |
              v
            Cosign
              |
              v
       update-values
              |
              v
        Gitea commit
        values.yaml
              |
              v
     CI webhook arrives
              |
              v
        CEL rejects
        CI self-push
```

---

### W27. Operational rule

For the normal developer workflow:

**What:** Creates and pushes a real developer commit.  
**Why:** Exercises the complete Gitea-to-Tekton trigger path.  
**How:** Run from the TravelPortal repository on branch `main`.

```bash
git add .
git commit -m "developer change"
git push origin main
```

The developer does NOT need to create a PipelineRun manually.

The system should automatically create:

```text
travelportal-build-xxxxx
```

and the pipeline chooses:

```text
BuildKit
```

or:

```text
Buildpacks
```

depending on the repository contents.

---

### W28. Important configuration rules

1. The Gitea repository URL must be:

```text
http://10.12.90.62/admin/travelPortal-test-buildpack.git
```

2. The production/lab branch used by the trigger must match the webhook payload:

```text
refs/heads/main
```

3. The webhook NodePort must match the actual generated Service:

```text
8080:31877
```

4. The Gitea `ALLOWED_HOST_LIST` must allow the Node IP:

```text
10.12.92.3
```

5. The EventListener ServiceAccount needs Triggers read access and PipelineRun creation access.

6. The TriggerTemplate must reference:

```text
travelportal-pipeline-values-update
```

7. The update-values Task must push to Gitea, not GitHub.

8. CI-generated commits must be prevented from creating another PipelineRun.

9. Never solve CI push races with `git push --force`.

10. Keep Gitea tokens in Kubernetes Secrets, not Pipeline YAML.

---

### W29. References

The documented trigger chain is `EventListener -> Interceptor -> TriggerBinding -> TriggerTemplate -> PipelineRun`; Tekton documents `serviceType: NodePort` for exposing an EventListener Service. Gitea documents `ALLOWED_HOST_LIST` as a comma-separated allow-list for webhook destinations and exposes `branch_filter` for repository webhooks.

This runbook follows the Tekton Triggers model of:

```text
EventListener -> Interceptor -> TriggerBinding -> TriggerTemplate -> PipelineRun
```

and the supported EventListener `kubernetesResource.serviceType: NodePort` configuration.

Reference documentation:

- Tekton EventListeners
- Tekton Triggers and EventListeners
- Tekton CEL Interceptors
- Tekton TriggerBindings
- Tekton TriggerTemplates
- Gitea Configuration Cheat Sheet (`security.ALLOWED_HOST_LIST`)

---

## Installation — Air-Gapped / Disconnected Environment

Same idea as before, but done in two stages: first, copy everything needed onto a machine that
still has internet access; then, run the whole pipeline on a cluster with **no** internet
access at all, using only what was copied over.

### 1. Set up a mirror workstation

Any machine with internet access, used only to copy images and download tool binaries — it
never touches the disconnected cluster directly.

```bash
mkdir -p airgap/{images,charts,manifests,binaries,checksums}
export HARBOR=harbor.example.internal
```

### 2. Download the CLI tools on the mirror workstation

These are the same tools installed in the internet-connected section, but here they're
downloaded once on the connected workstation and carried across to the disconnected side —
the `curl`/`github.com` calls in the internet-connected steps won't work once you're offline.

```bash
cd airgap/binaries

# BuildKit CLI (buildctl / buildkitd)
curl -fsSL -o buildkit.tar.gz \
  https://github.com/moby/buildkit/releases/latest/download/buildkit-linux-amd64.tar.gz

# Pack CLI
curl -sSL -o pack.tgz \
  "https://github.com/buildpacks/pack/releases/download/v${PACK_VERSION}/pack-v${PACK_VERSION}-linux.tgz"

# tkn CLI (Tekton)
curl -LO https://github.com/tektoncd/cli/releases/download/${TEKTON_VERSION}/tkn_${TEKTON_VERSION#v}_Linux_x86_64.tar.gz

# Cosign
curl -LO https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/cosign-linux-amd64

# Syft
curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh \
  | sh -s -- -b . ${SYFT_VERSION}

cd ../..
```

Copy the whole `airgap/binaries/` folder across to the disconnected side using your normal
transfer process (USB, secure file transfer, etc.), then install each one the same way the
internet-connected section does — `tar -xzf`, `install -m 0755`, and so on — just from the
local files instead of a fresh `curl` download.

### 3. Copy the BuildKit, Buildpacks, Tekton, Cosign, and Syft container images to Harbor

```bash
# BuildKit
skopeo copy docker://${BUILDKIT_IMAGE} \
  docker://$HARBOR/buildkit/buildkit:latest

# Buildpacks — builder and run image (mirror BOTH, one alone isn't enough)
skopeo copy docker://${BUILDER_IMAGE} \
  docker://$HARBOR/buildpacks/builder-jammy-base:latest
skopeo copy docker://${RUN_IMAGE}:latest \
  docker://$HARBOR/buildpacks/run-jammy-base:latest
skopeo copy docker://buildpacksio/pack:${PACK_VERSION} \
  docker://$HARBOR/buildpacks/pack:${PACK_VERSION}

# Tekton — pull the release files first, then mirror every image they reference
curl -sL -o pipeline.yaml \
  https://storage.googleapis.com/tekton-releases/pipeline/previous/${TEKTON_VERSION}/release.yaml
curl -sL -o triggers.yaml \
  https://storage.googleapis.com/tekton-releases/triggers/previous/${TRIGGERS_VERSION}/release.yaml
curl -sL -o interceptors.yaml \
  https://storage.googleapis.com/tekton-releases/triggers/previous/${TRIGGERS_VERSION}/interceptors.yaml
curl -sL -o dashboard.yaml \
  https://storage.googleapis.com/tekton-releases/dashboard/previous/${DASHBOARD_VERSION}/release.yaml
grep -Eo 'image: .*' pipeline.yaml triggers.yaml interceptors.yaml dashboard.yaml | awk '{print $2}' | sort -u > tekton-images.txt
while read -r img; do
  skopeo copy "docker://${img}" "docker://${HARBOR}/tekton/$(basename "${img}" | tr ':' '_')"
done < tekton-images.txt

# Cosign and Syft (container images, used by the sign/SBOM steps inside buildkit-build and buildpacks-build)
skopeo copy docker://gcr.io/projectsigstore/cosign:${COSIGN_VERSION} \
  docker://${HARBOR}/tools/cosign:${COSIGN_VERSION}
skopeo copy docker://anchore/syft:${SYFT_VERSION} \
  docker://${HARBOR}/tools/syft:${SYFT_VERSION}
```

### 4. Point every install file at Harbor instead of the public internet

```bash
for f in pipeline.yaml triggers.yaml interceptors.yaml dashboard.yaml; do
  while read -r img; do
    mirrored="${HARBOR}/tekton/$(basename "${img}" | tr ':' '_')"
    sed -i "s#${img}#${mirrored}#g" "${f}"
  done < tekton-images.txt
done

pack config run-image-mirrors add \
  index.docker.io/paketobuildpacks/run-jammy-base:latest \
  --mirror "$HARBOR/buildpacks/run-jammy-base:latest"
```

### 5. Install everything on the disconnected cluster

```bash
kubectl apply -f pipeline.yaml
kubectl apply -f triggers.yaml
kubectl apply -f interceptors.yaml
kubectl apply -f dashboard.yaml
```

Every Tekton `Task` YAML shown in the previous section (`detect-build-type`, `buildkit-build`,
`buildpacks-build`) needs its `image:` fields changed to point at `${HARBOR}/...` too, including
the `anchore/syft` and `gcr.io/projectsigstore/cosign` images used in the signing steps inside
`buildkit-build`/`buildpacks-build` — same rule as everywhere else in this guide.

**Set up the same Harbor push secret** used in the internet-connected section (step 8) — this
isn't internet-dependent, so it's just repeated here on the disconnected cluster:

```bash
kubectl create secret docker-registry harbor-credentials \
  --docker-server="$HARBOR" \
  --docker-username='<ROBOT_USERNAME>' \
  --docker-password='<ROBOT_TOKEN>' \
  -n cicd
```

**Generate the Cosign signing key directly on the disconnected cluster** — this step needs no
internet access at all, so there's no reason to generate it on the mirror workstation and
transfer a private key across:

```bash
cosign generate-key-pair k8s://${CI_NS}/cosign-key
```

**Expose the Dashboard** the same way as the internet-connected section (step 10) — the
`VirtualService` pointing at `tekton-dashboard.tekton-pipelines.svc.cluster.local` works
identically here, since it's all internal cluster routing with no dependency on public
internet.

### 6. Prove it works with no internet at all

Block public internet access from the `cicd` namespace, then run the pipeline exactly as in
step 14 of the Internet-Connected section (or by pushing to Gitea, if you set up the
*Automatic Triggering* section). If it completes and `cosign verify` succeeds using only the
mirrored images, the offline setup is working correctly.

### 7. Final air-gap checklist

- [ ] Public registries and internet access are blocked from the build namespace.
- [ ] Every build-time image pull resolves to Harbor — including Tekton, Cosign, and Syft, not
      just BuildKit and Buildpacks.
- [ ] `buildctl`, `pack`, `tkn`, `cosign`, and `syft` CLI binaries were installed from the
      transferred `airgap/binaries/` folder, not a live `curl`/GitHub download.
- [ ] The Harbor push secret and the Cosign signing key exist on the disconnected cluster.
- [ ] The Tekton Dashboard is reachable at its internal address (TLS + DNS working).
- [ ] A `Dockerfile` build works using only mirrored base images (BuildKit).
- [ ] A no-`Dockerfile` build works using only the mirrored builder and run image (Buildpacks).
- [ ] The pipeline signs the image and attests the SBOM using only the local Cosign key — no
      outside network calls.
- [ ] `interceptors.yaml` (the CEL interceptor) was mirrored and applied along with `triggers.yaml`, if the webhook trigger is used.
- [ ] The Gitea webhook reaches the EventListener NodePort and Gitea's `ALLOWED_HOST_LIST` includes the node IP, if the webhook trigger is used.
- [ ] Build logs show no public registry access at all.

---

## Conclusion

Put simply: a developer pushes code, and everything from that point on happens on its own.
Tekton checks whether there's a `Dockerfile` and picks BuildKit or Buildpacks accordingly,
builds the image, writes down exactly what went into it, signs both the image and that record
with Cosign, and hands the finished, verified image to Harbor — ready for ArgoCD to deploy.
The same steps work identically whether the cluster is online or completely disconnected from
the internet, so there's one process to learn, trust, and audit, everywhere.

Before this goes live: replace every placeholder value (hostnames, credentials, namespaces,
registry URLs, image versions) with your real environment's values, generate and safely store
your own Cosign key, and run through the air-gapped checklist even if you're currently
online — it's the easiest way to catch a missing mirror before it becomes a production
incident.
