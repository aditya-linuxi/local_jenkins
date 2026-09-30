# BuildKit & Cloud Native Buildpacks on vSphere Kubernetes Service (VKS)
 
> **In one line:** this document explains how we automatically turn a developer's code push into
> a secure, signed container image — and then into an updated deployment — doing it the same way
> whether the app has a `Dockerfile` or not, using **Gitea** as the Git server and **Tekton** as
> the automation engine, running on **VMware VKS**.
 
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
 
**Tekton** is the piece that makes this automatic. Every time a developer pushes code to
**Gitea** (our internal Git server), Gitea sends Tekton a short "something was pushed" message
(a **webhook**). Tekton wakes up, checks whether there's a `Dockerfile`, picks the right tool
(BuildKit or Buildpacks), builds the image, generates a paper trail for it (a **Software Bill of
Materials**, or SBOM — basically an ingredients list for the image), **digitally signs** both
the image and that ingredients list using **Cosign**, and pushes everything to our internal
image store, **Harbor**. As a final step, Tekton writes the new image's fixed ID (its digest)
into the app's deployment file (`helm-charts/values.yaml`) and saves that change back to Gitea,
so **ArgoCD** can roll it out. No person has to do any of these steps by hand.
 
This document covers:
1. How BuildKit and Buildpacks build images.
2. How Tekton runs and automates that whole process on VKS — from the Gitea push, through
   signing, to the updated deployment file.
3. How to run the same setup in a fully offline ("air-gapped") environment.
---
 
## Why use BuildKit and Buildpacks with Tekton on VKS?
 
In plain terms, here's why this combination makes sense:
 
- **One automatic process for everyone.** Whether or not a team wrote a `Dockerfile`, their
  code still gets built the same reliable way — Tekton decides which tool to use, so nobody
  has to remember or configure it manually.
- **Nothing gets built by hand.** A person pushing code is the only manual step. Everything
  after that — building, checking for security issues, signing, publishing, updating the
  deployment file — happens on its own.
- **A push starts the build by itself.** Gitea tells Tekton the moment code arrives, so nobody
  has to click "run" or create a pipeline run manually.
- **The pipeline never triggers itself in a loop.** Tekton saves the new image ID back to Git,
  and a built-in filter makes sure that save doesn't start another build.
- **Trust is built in, not bolted on.** Every image gets signed and gets an ingredients list
  (SBOM) the moment it's built — not added later as an afterthought. Harbor can then refuse to
  hand out any image that isn't signed.
- **It all runs on the same platform.** VKS already gives us the cluster, the storage, the
  networking, Harbor (image store), and ArgoCD (deployment) — Tekton just plugs into what's
  already there instead of needing its own separate servers.
- **Works with no internet too.** Everything described here — Gitea, BuildKit, Buildpacks,
  Tekton, and Cosign — can run fully offline, which matters for secure/air-gapped environments.
- **One dashboard to watch it all.** Tekton's Dashboard shows every build, whether it succeeded
  or failed, and why — in a web page, not just log files.
---
 
## Benefits
 
| Benefit | In simple words |
|---|---|
| **No guesswork on how to build** | Tekton always knows: `Dockerfile` present → BuildKit, absent → Buildpacks. |
| **Less work for app teams** | Teams don't need to write or maintain a `Dockerfile` if they don't want to — Buildpacks handles it for them. |
| **Fully automatic** | A code push is the only human action; the build, sign, publish, and deployment-file update steps run by themselves. |
| **Push-to-build** | Gitea's webhook starts the pipeline the moment code lands on `main` — no manual pipeline runs. |
| **No build loops** | The pipeline's own commit is recognised and ignored, so it can't trigger itself forever. |
| **Every image is signed** | Cosign signs the image and its ingredients list (SBOM) right after it's built, so nothing unverified reaches production. |
| **Safer builds** | BuildKit and Buildpacks both run without needing root/admin access inside the cluster. |
| **Safe Git updates** | When the pipeline saves the new image ID back to Git, it first syncs with the latest code — it never force-pushes over a developer's work. |
| **One place for images** | Every built image lands in Harbor, where it's scanned, verified, and stored. |
| **Same steps everywhere** | The exact same pipeline works whether the cluster has internet access or is completely offline. |
| **You can always prove what's running** | Images are tracked by a fixed ID (a digest), not a name that can change, that ID is written into Git, and each image has a matching signed ingredients list. |
| **One dashboard for visibility** | Anyone can open the Tekton Dashboard and see the status of every build, without needing cluster access. |
 
---
 
## Architecture
 
All of this — Gitea, Tekton, BuildKit, Buildpacks, and Cosign — runs **inside the VKS cluster**
itself. Nothing extra needs to be installed outside it. Here's the whole journey from
"developer pushes code" to "signed image is deployed" — everything after step 1 happens
automatically, with no manual steps:
 
```
 1. Developer pushes code to Gitea
             │
             ▼
 2. Gitea sends a "push" message (webhook)
    to the Tekton EventListener
             │
             ▼
 3. Tekton filters the message: main branch only,
    and ignore commits made by the pipeline itself
             │
             ▼
 4. Tekton starts a new pipeline run
             │
             ▼
 5. Tekton downloads the code and checks:
    does this repo have a Dockerfile?
             │
    ┌────────┴────────┐
   Yes                 No
    │                   │
    ▼                   ▼
 6a. BuildKit        6b. Buildpacks
 builds the image     builds the image
 (using the           (using paketo
  Dockerfile)          builder-jammy-base)
    │                   │
    └────────┬──────────┘
             ▼
 7. An ingredients list (SBOM) is created for the image
             │
             ▼
 8. The image AND the ingredients list are digitally
    signed with Cosign
             │
             ▼
 9. Everything is pushed to Harbor
    (Harbor scans it and checks the signature)
             │
             ▼
10. Harbor stores the image with a fixed ID (digest)
             │
             ▼
11. Tekton writes that ID into helm-charts/values.yaml
    and commits it back to Gitea (marked as a CI commit,
    so step 3 ignores it)
             │
             ▼
12. ArgoCD sees the updated deployment file and
    deploys the new, signed image onto VKS
```
 
| Step | What it means in plain words |
|---|---|
| Developer pushes code | The only thing a person actually has to do |
| Gitea | The Git server — holds the code and the deployment file, and sends the push message |
| Webhook | The "something was pushed" message Gitea sends to Tekton |
| Tekton | The automation engine — receives the message and runs the whole pipeline |
| EventListener | The Tekton door that the webhook knocks on |
| CEL filter | A short rule that only lets `main` branch pushes through, and blocks the pipeline's own commits |
| TriggerBinding / TriggerTemplate | Read the push message, then turn it into a pipeline run |
| Dockerfile check | The one decision point: which tool builds the image |
| BuildKit / Buildpacks | The two ways an image actually gets built |
| SBOM (ingredients list) | A record of everything that went into the image, for security and audit |
| Cosign signing | Proves the image really came from our pipeline and hasn't been tampered with |
| Harbor | Where every image is stored, scanned, and checked for a valid signature |
| `update-values` | The last pipeline step — writes the new image ID into Git for ArgoCD to pick up |
| ArgoCD | Takes the newly signed image and rolls it out to the running application |
 
Here's what steps 2–4 look like up close — the "trigger chain" inside Tekton:
 
```
 Gitea webhook (POST)
        │
        ▼
 NodePort  ──►  EventListener  ──►  CEL filter  ──►  TriggerBinding  ──►  TriggerTemplate
                                    (main only,      (reads repo,         (creates the
                                     no CI loops)     branch, commit)      PipelineRun)
                                                                                │
                                                                                ▼
                                                                    app-build-pipeline runs
```
 
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
| Gitea | Helm chart `gitea-charts/gitea` 12.7.0 (validated) | The Git server — holds the code, sends the push webhook, stores the deployment file |
| Tekton Pipelines | Latest version supported by your cluster | Runs the CI pipeline — the automation engine described above |
| Tekton Triggers | Same release train as Pipelines | Receives the Gitea webhook and starts the pipeline (EventListener + CEL filter) |
| Tekton Dashboard | Same release train as Pipelines | The web page for watching build status |
| Cosign | Latest stable | Signs images and their ingredients lists (SBOMs) |
| Syft | Latest stable | Generates the ingredients list (SBOM) for each image |
 
> VCF and VKS ship together — this guide is pinned to **VCF 9.x**, with VKS bundled as part of
> that release. Every other version below (BuildKit, Pack, Tekton, Cosign, Syft) is validated
> against this VCF 9.x baseline — update them together, as a set, if you move to a newer VCF
> release.
 
### What your application repository needs
 
- The code lives in a Gitea repository, and builds are triggered from the `main` branch.
- A Helm deployment file at `helm-charts/values.yaml` with an `image:` block that already
  contains `repository`, `tag`, and `digest` keys. The pipeline's last step edits exactly those
  three values.
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
export HARBOR=lab25-harbor.lab25.sunfire.lab
export GITEA=10.12.90.62
export CI_NS=cicd
export APP_NS=sample-app
export GITEA_NS=gitea
 
# Workload node that Gitea sends its webhook to (see step 17)
export NODE_IP=10.12.92.3
 
# Port Tekton opens for the webhook (confirmed in step 17: 8080 -> 31877)
export WEBHOOK_NODEPORT=31877
 
# Versions validated against VCF 9.x / VKS — update together if you move to a newer VCF release
export GITEA_CHART_VERSION=12.7.0
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
| Git server | Gitea (in-cluster, Helm-managed) — sends the push webhook and stores the deployment file |
| Automation engine | Tekton Pipelines + Triggers + Dashboard |
| Trigger chain | Gitea webhook → EventListener (NodePort) → CEL filter → TriggerBinding → TriggerTemplate → PipelineRun |
| Trigger filter | `main` branch only; commits made by the pipeline itself are ignored |
| Signing & trust | Cosign (signs images and SBOM attestations) + Syft (generates SBOMs) |
| Deployment file update | Final pipeline step commits the new image digest to `helm-charts/values.yaml` in Gitea |
| Target platform | vSphere Kubernetes Service (VKS), bundled with VCF 9.x |
| Registry | Harbor (OCI registry, scanning, signing, and signature verification) |
| Default builder | `paketobuildpacks/builder-jammy-base` |
| Default run image | `index.docker.io/paketobuildpacks/run-jammy-base` (used automatically by the builder above) |
| BuildKit image | `moby/buildkit:latest` |
| Supported modes | Internet-connected **and** air-gapped/disconnected |
 
What has to already be in place before this build-and-sign pipeline is turned on:
 
- **Regional Harbor** — install and configure this first; it's where everything ends up.
- **Gitea** — running in the cluster (namespace `gitea`), with the application repository
  created and its `main` branch pushed. Gitea was installed with Helm, so the webhook setting
  in step 18 is applied through a Helm upgrade.
- **Argo CD** — recommended, so a signed image can move straight to deployment through GitOps.
  It should watch `helm-charts/values.yaml` in the same Gitea repository.
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
6. Write the new image ID into `helm-charts/values.yaml` and commit it back to Gitea.
This logic lives in a small number of Tekton building blocks (called `Task`s), tied together
into one `Pipeline`:
 
- **`detect-build-type`** — looks for a `Dockerfile` and records the answer.
- **`buildkit-build`** — runs when a `Dockerfile` was found; builds the image, then signs it
  and its SBOM as the final steps in the same Task.
- **`buildpacks-build`** — runs when no `Dockerfile` was found, using `$BUILDER_IMAGE`; builds
  the image, then signs it and its SBOM as the final steps in the same Task.
- **`update-values`** — runs after whichever build Task ran; writes the new image ID into the
  deployment file and commits it to Gitea.
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
        cp $(results.IMAGE_DIGEST.path) $(workspaces.source.path)/image-digest
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
        cp $(results.IMAGE_DIGEST.path) $(workspaces.source.path)/image-digest
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
 
> **Why the `write-digest` step also saves a file:** only one of the two build Tasks runs on
> any given build, and a later Task can't safely read a result from a Task that was skipped. So
> both build Tasks save the image ID in two places — as the Tekton result `IMAGE_DIGEST`, and as
> a plain file, `image-digest`, in the shared workspace. `update-values` reads that file, so it
> works the same way no matter which build ran.
 
The last Task writes the new image ID into the deployment file. Before changing anything it
syncs with the latest code in Gitea, so it never overwrites a developer's newer commit:
 
```yaml
apiVersion: tekton.dev/v1
kind: Task
metadata:
  name: update-values
  namespace: cicd
spec:
  params:
    - name: repo-url
      type: string
    - name: revision
      type: string
      default: main
    - name: image
      type: string
  workspaces:
    - name: source
  steps:
    - name: update
      image: alpine/git:latest
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
      script: |
        #!/bin/sh
        set -eu
        cd "$(workspaces.source.path)"
        git config --global --add safe.directory "$(workspaces.source.path)"
        git config user.name  "tekton-ci"
        git config user.email "tekton-ci@example.internal"
 
        # Point git at Gitea (built from the pipeline parameter — never hard-coded)
        REPO_URL="$(params.repo-url)"
        git remote set-url origin \
          "${REPO_URL%%://*}://${GIT_USERNAME}:${GIT_TOKEN}@${REPO_URL#*://}"
 
        # Sync with the newest code first, so the push can't be rejected or overwrite anyone
        git fetch origin "$(params.revision)"
        git reset --hard "origin/$(params.revision)"
 
        # Write the new image ID into the deployment file
        DIGEST="$(cat image-digest)"
        IMAGE="$(params.image)"
        IMAGE_REPO="${IMAGE%:*}"
        IMAGE_TAG="${IMAGE##*:}"
 
        sed -i -E "/^image:/,/^[A-Za-z]/{
          s|^([[:space:]]+repository:).*|\1 ${IMAGE_REPO}|
          s|^([[:space:]]+tag:).*|\1 \"${IMAGE_TAG}\"|
          s|^([[:space:]]+digest:).*|\1 \"${DIGEST}\"|
        }" helm-charts/values.yaml
 
        if git diff --quiet helm-charts/values.yaml; then
          echo "values.yaml already up to date — nothing to commit."
          exit 0
        fi
 
        # This exact message prefix is what the EventListener filter (step 17) ignores
        git add helm-charts/values.yaml
        git commit -m "ci: update TravelPortal image digest"
        git push origin "HEAD:$(params.revision)"
```
 
> **Two rules this Task follows on purpose:**
> - It never uses `git push --force`. If Gitea ever rejects the push with *"fetch first"*, it
>   means a newer commit arrived mid-run; the fetch-and-reset above already handles the normal
>   case, and a rare collision is fixed by simply re-running the pipeline.
> - The commit message must start with exactly `ci: update TravelPortal image digest`. If you
>   change it here, change the EventListener filter in step 17 to match, or the pipeline will
>   trigger itself.
 
Finally, one `Pipeline` ties the four `Task`s together, using a `when` condition so that only
**one** of `buildkit-build` / `buildpacks-build` runs on any given build — whichever one
matches what `detect-build-type` found. Signing and SBOM attestation happen automatically as
the last steps inside whichever build Task runs — there's no separate signing stage in the
Pipeline itself. `update-values` then runs once the chosen build has finished:
 
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
 
    - name: update-values
      taskRef: { name: update-values }
      runAfter: ["buildkit-build", "buildpacks-build"]
      params:
        - { name: repo-url, value: $(params.repo-url) }
        - { name: revision, value: $(params.revision) }
        - { name: image, value: $(params.image) }
      workspaces: [{ name: source, workspace: shared-workspace }]
```
 
### 14. Give the pipeline permission to write back to Gitea
 
`update-values` needs to push a commit, so it needs a Gitea account it can use. Create a
dedicated Personal Access Token in Gitea (limited to this repository), then store it as a
Kubernetes Secret — never paste it into a Task or Pipeline file:
 
```bash
kubectl create secret generic gitea-git-credentials \
  -n cicd \
  --from-literal=username='admin' \
  --from-literal=token='<GITEA_TOKEN>'
```
 
### 15. Give the EventListener the right permissions
 
The EventListener is the "door" Gitea knocks on. It runs under its own Kubernetes identity, and
that identity needs to be allowed to read Tekton's trigger settings and create pipeline runs.
Two of the trigger objects are cluster-wide (`clusterinterceptors`, `clustertriggerbindings`),
so a cluster-level role is needed as well as a namespace one. Save all of this in one file,
`gitea-trigger-rbac.yaml`, so it's easy to repeat:
 
```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: gitea-trigger-sa
  namespace: cicd
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: gitea-trigger-role
  namespace: cicd
rules:
  - apiGroups: ["triggers.tekton.dev"]
    resources: ["eventlisteners", "triggerbindings", "triggertemplates", "triggers", "interceptors"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["tekton.dev"]
    resources: ["pipelineruns"]
    verbs: ["create", "get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: gitea-trigger-rolebinding
  namespace: cicd
subjects:
  - kind: ServiceAccount
    name: gitea-trigger-sa
    namespace: cicd
roleRef:
  kind: Role
  name: gitea-trigger-role
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: gitea-trigger-cluster-role
rules:
  - apiGroups: ["triggers.tekton.dev"]
    resources: ["clusterinterceptors", "clustertriggerbindings"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: gitea-trigger-cluster-rolebinding
subjects:
  - kind: ServiceAccount
    name: gitea-trigger-sa
    namespace: cicd
roleRef:
  kind: ClusterRole
  name: gitea-trigger-cluster-role
  apiGroup: rbac.authorization.k8s.io
```
 
```bash
kubectl apply -f gitea-trigger-rbac.yaml
```
 
Confirm the permissions actually work — every line should answer `yes`:
 
```bash
SA=system:serviceaccount:cicd:gitea-trigger-sa
 
for r in triggerbindings triggertemplates eventlisteners; do
  kubectl auth can-i list $r.triggers.tekton.dev --as=$SA -n cicd
done
kubectl auth can-i list clusterinterceptors.triggers.tekton.dev --as=$SA
kubectl auth can-i list clustertriggerbindings.triggers.tekton.dev --as=$SA
kubectl auth can-i create pipelineruns.tekton.dev --as=$SA -n cicd
```
 
> Don't grant `pods:create` to this account just because some other check says `no`. The
> EventListener's pod is created by Kubernetes itself, not by this account.
 
### 16. Tell Tekton how to read a push and what to run
 
Two small objects do this. The **TriggerBinding** reads the fields it needs from Gitea's push
message; the **TriggerTemplate** uses them to create the pipeline run.
 
The repository URL and branch are fixed on purpose in the binding — this keeps differences
between Git servers' message formats from ever affecting which repository gets built.
 
```yaml
apiVersion: triggers.tekton.dev/v1beta1
kind: TriggerBinding
metadata:
  name: gitea-binding
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
 
```yaml
apiVersion: triggers.tekton.dev/v1beta1
kind: TriggerTemplate
metadata:
  name: gitea-template
  namespace: cicd
spec:
  params:
    - name: REPO_URL
    - name: REVISION
      default: main
    - name: COMMIT_MESSAGE
      default: Gitea push
    - name: COMMIT_SHA
  resourcetemplates:
    - apiVersion: tekton.dev/v1
      kind: PipelineRun
      metadata:
        generateName: app-build-
        annotations:
          commit-sha: $(tt.params.COMMIT_SHA)
      spec:
        pipelineRef:
          name: app-build-pipeline
        params:
          - name: repo-url
            value: $(tt.params.REPO_URL)
          - name: revision
            value: $(tt.params.REVISION)
          - name: image
            value: lab25-harbor.lab25.sunfire.lab/cicd/travelportal:latest
        taskRunTemplate:
          serviceAccountName: default
        timeouts:
          pipeline: 1h0m0s
        workspaces:
          - name: shared-workspace
            persistentVolumeClaim:
              claimName: buildpacks-source-pvc
```
 
```bash
kubectl apply -f triggerbinding.yaml
kubectl apply -f triggertemplate.yaml
```
 
### 17. Create the EventListener — the door Gitea knocks on
 
The EventListener ties everything together: it's exposed as a **NodePort** so Gitea can reach
it, its CEL filter decides whether a push should start a build, and it hands accepted pushes to
the binding and template from step 16.
 
The filter lets through pushes to `main` **and** blocks any commit whose message starts with
`ci: update TravelPortal image digest` — that's the commit `update-values` makes. Without this
second half, the pipeline's own commit would trigger a new build, which would make another
commit, and so on forever.
 
```yaml
apiVersion: triggers.tekton.dev/v1beta1
kind: EventListener
metadata:
  name: gitea-listener
  namespace: cicd
spec:
  serviceAccountName: gitea-trigger-sa
  resources:
    kubernetesResource:
      serviceType: NodePort
  triggers:
    - name: gitea-push
      interceptors:
        - ref:
            apiVersion: triggers.tekton.dev
            kind: ClusterInterceptor
            name: cel
          params:
            - name: filter
              value: >-
                body.ref == 'refs/heads/main' &&
                !body.head_commit.message.startsWith('ci: update TravelPortal image digest')
      bindings:
        - ref: gitea-binding
      template:
        ref: gitea-template
```
 
```bash
kubectl apply -f eventlistener.yaml
 
kubectl get eventlistener gitea-listener -n cicd     # expect AVAILABLE=True, READY=True
kubectl get svc el-gitea-listener -n cicd
```
 
Tekton picks the NodePort number for you, so read it from the Service instead of guessing. The
service shows two ports; the webhook must use the one mapped to **8080** (the other, 9000, is
not for webhooks):
 
```bash
export WEBHOOK_NODEPORT=$(kubectl get svc el-gitea-listener -n cicd \
  -o jsonpath='{.spec.ports[?(@.port==8080)].nodePort}')
 
echo "Webhook URL: http://${NODE_IP}:${WEBHOOK_NODEPORT}"
```
 
In this environment the result is `31877`, so the webhook URL is `http://10.12.92.3:31877`. If a
run ever gives a different number, use that one — never a remembered or old port (for example
`31878` is wrong here).
 
> **Optional — a stronger loop guard.** Instead of checking the commit message, the filter can
> check which files changed and ignore any push that only touched `helm-charts/values.yaml`
> (the only file the pipeline edits). Swap this in for the `filter` value above — but test it
> against a real Gitea delivery first, since it depends on the push message containing the
> `commits[].added / modified / removed` lists:
>
> ```
> body.ref == 'refs/heads/main' &&
> body.commits.exists(c,
>   c.added.exists(f, f != 'helm-charts/values.yaml') ||
>   c.modified.exists(f, f != 'helm-charts/values.yaml') ||
>   c.removed.exists(f, f != 'helm-charts/values.yaml')
> )
> ```
>
> Adding `helm-charts/values.yaml` to `.gitignore` will **not** solve the loop — the file is
> already tracked by Git, and `.gitignore` doesn't stop tracked files from being committed. The
> loop has to be stopped at the filter.
 
### 18. Let Gitea call Tekton
 
By default Gitea refuses to send webhooks to internal addresses, and shows *"webhook can only
call allowed HTTP servers"*. Gitea was installed with Helm, so add the node address to its
allow-list through the chart's environment-variable override (this is the form that reliably
reaches Gitea's config; setting `gitea.config.security.ALLOWED_HOST_LIST` directly did not):
 
```bash
cat > /tmp/gitea-webhook-values.yaml <<EOF
gitea:
  additionalConfigFromEnvs:
    - name: GITEA__SECURITY__ALLOWED_HOST_LIST
      value: "${GITEA},${NODE_IP}"
EOF
 
helm upgrade gitea gitea-charts/gitea \
  -n ${GITEA_NS} \
  --version ${GITEA_CHART_VERSION} \
  --reuse-values \
  -f /tmp/gitea-webhook-values.yaml
 
kubectl rollout status deployment/gitea -n ${GITEA_NS}
```
 
`--reuse-values` keeps all your existing Gitea settings and only adds this one. Confirm it
reached Gitea's real config file:
 
```bash
kubectl exec -n ${GITEA_NS} deployment/gitea -- \
  grep -n 'ALLOWED_HOST_LIST' /data/gitea/conf/app.ini
```
 
### 19. Test the EventListener by hand
 
Before involving Gitea, check that the listener is alive and accepts a push message. First the
plumbing — the Service must have a live pod behind it on port 8080:
 
```bash
kubectl get endpoints el-gitea-listener -n cicd -o wide
kubectl get pods -n cicd -l eventlistener=gitea-listener -o wide
```
 
Then send a fake push message shaped like Gitea's:
 
```bash
cat > /tmp/test-event.json <<'EOF'
{
  "ref": "refs/heads/main",
  "after": "test-sha",
  "head_commit": { "message": "test webhook" }
}
EOF
 
curl -v \
  -H 'Content-Type: application/json' \
  --data-binary @/tmp/test-event.json \
  http://${NODE_IP}:${WEBHOOK_NODEPORT}
```
 
`HTTP/1.1 202 Accepted` means the path *machine → NodePort → EventListener* works, and a new
`app-build-*` pipeline run should appear (`kubectl get pipelineruns -n cicd`).
 
### 20. Add the webhook in Gitea
 
In Gitea, open the repository and go to **Settings → Webhooks → Add Webhook → Gitea**, then
fill it in like this:
 
| Setting | Value |
|---|---|
| Target URL | `http://10.12.92.3:31877` |
| HTTP method | `POST` |
| Content type | `application/json` |
| Trigger on | Push events |
| Branch filter | `main` |
 
Save it, then use **Test Delivery** or push a real commit. The filter and binding only rely on
three fields of Gitea's message, so nothing else needs configuring:
 
| Field in the push message | Used for |
|---|---|
| `ref` | Deciding whether it's the `main` branch |
| `after` | The commit ID |
| `head_commit.message` | The commit message (also how CI commits are recognised) |
 
Gitea's message also carries GitHub-style headers, but the EventListener doesn't need the GitHub
interceptor here.
 
### 21. Run it and check the result
 
From now on, nobody creates a pipeline run by hand. A normal developer push is all it takes:
 
```bash
git add .
git commit -m "developer change"
git push origin main
```
 
Then watch it happen:
 
```bash
kubectl get pipelineruns -n cicd -w
kubectl logs -f deployment/el-gitea-listener -n cicd     # what the listener decided
 
tkn pipelinerun logs -f -n cicd
 
cosign verify --key cosign.pub ${HARBOR}/cicd/travelportal:latest
```
 
You should see one `app-build-*` run start, either `buildkit-build` or `buildpacks-build` run
(not both), the image signed, and one extra commit from `tekton-ci` appear in Gitea changing
`helm-charts/values.yaml`. That commit must **not** start a second run.
 
To test the pipeline on its own, without Gitea, you can still start it manually:
 
```bash
tkn pipeline start app-build-pipeline -n cicd \
  -p repo-url=http://${GITEA}/admin/travelPortal-test-buildpack.git \
  -p revision=main \
  -p image=${HARBOR}/cicd/travelportal:latest \
  -w name=shared-workspace,claimName=buildpacks-source-pvc
```
 
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
export HARBOR=lab25-harbor.lab25.sunfire.lab
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
 
# Tekton — pull the release files first, then mirror every image they reference.
# Pipelines, Triggers, and Dashboard each have their own version, and Triggers ships a
# separate interceptors file (it holds the CEL filter the EventListener depends on).
BASE=https://storage.googleapis.com/tekton-releases
curl -sL -o pipeline.yaml     ${BASE}/pipeline/previous/${TEKTON_VERSION}/release.yaml
curl -sL -o triggers.yaml     ${BASE}/triggers/previous/${TRIGGERS_VERSION}/release.yaml
curl -sL -o interceptors.yaml ${BASE}/triggers/previous/${TRIGGERS_VERSION}/interceptors.yaml
curl -sL -o dashboard.yaml    ${BASE}/dashboard/previous/${DASHBOARD_VERSION}/release.yaml
 
grep -Eho 'image: .*' pipeline.yaml triggers.yaml interceptors.yaml dashboard.yaml \
  | awk '{print $2}' | sort -u > tekton-images.txt
while read -r img; do
  skopeo copy "docker://${img}" "docker://${HARBOR}/tekton/$(basename "${img}" | tr ':' '_')"
done < tekton-images.txt
 
# Cosign and Syft (container images, used by the sign/SBOM steps inside buildkit-build and buildpacks-build)
skopeo copy docker://gcr.io/projectsigstore/cosign:${COSIGN_VERSION} \
  docker://${HARBOR}/tools/cosign:${COSIGN_VERSION}
skopeo copy docker://anchore/syft:${SYFT_VERSION} \
  docker://${HARBOR}/tools/syft:${SYFT_VERSION}
 
# Small helper images used by detect-build-type, write-digest, and update-values
skopeo copy docker://alpine:3.20 \
  docker://${HARBOR}/tools/alpine:3.20
skopeo copy docker://alpine/git:latest \
  docker://${HARBOR}/tools/git:latest
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
`buildpacks-build`, `update-values`) needs its `image:` fields changed to point at `${HARBOR}/...`
too, including the `anchore/syft` and `gcr.io/projectsigstore/cosign` images used in the signing
steps inside `buildkit-build`/`buildpacks-build`, and the `alpine` and `alpine/git` helper images
— same rule as everywhere else in this guide.
 
**Set up the same Harbor push secret** used in the internet-connected section (step 8) — this
isn't internet-dependent, so it's just repeated here on the disconnected cluster:
 
```bash
kubectl create secret docker-registry harbor-credentials \
  --docker-server="$HARBOR" \
  --docker-username='<ROBOT_USERNAME>' \
  --docker-password='<ROBOT_TOKEN>' \
  -n cicd
```
 
**Set up the same Gitea write-back secret** used in step 14 — again, nothing here depends on the
internet, and Gitea is already inside the disconnected environment:
 
```bash
kubectl create secret generic gitea-git-credentials \
  -n cicd \
  --from-literal=username='admin' \
  --from-literal=token='<GITEA_TOKEN>'
```
 
**Generate the Cosign signing key directly on the disconnected cluster** — this step needs no
internet access at all, so there's no reason to generate it on the mirror workstation and
transfer a private key across:
 
```bash
cosign generate-key-pair k8s://${CI_NS}/cosign-key
```
 
**Set up the trigger chain and the Gitea webhook** exactly as in steps 15–20 of the previous
section (permissions, binding and template, EventListener, the Gitea allow-list, and the webhook
itself). Every one of those is internal cluster and Gitea traffic, so nothing changes — the only
edit is that any `image:` fields in your own YAML must point at Harbor.
 
**Expose the Dashboard** the same way as the internet-connected section (step 10) — the
`VirtualService` pointing at `tekton-dashboard.tekton-pipelines.svc.cluster.local` works
identically here, since it's all internal cluster routing with no dependency on public
internet.
 
### 6. Prove it works with no internet at all
 
Block public internet access from the `cicd` namespace, then push a commit to `main` in Gitea
and let the webhook start the pipeline exactly as in step 21 of the previous section. If the run
completes, `cosign verify` succeeds, and the CI commit to `helm-charts/values.yaml` appears
without starting a second run — all using only the mirrored images — the offline setup is
working correctly.
 
### 7. Final air-gap checklist
 
- [ ] Public registries and internet access are blocked from the build namespace.
- [ ] Every build-time image pull resolves to Harbor — including Tekton (with the Triggers
      interceptors), Cosign, Syft, and the `alpine` / `alpine/git` helper images, not just
      BuildKit and Buildpacks.
- [ ] `buildctl`, `pack`, `tkn`, `cosign`, and `syft` CLI binaries were installed from the
      transferred `airgap/binaries/` folder, not a live `curl`/GitHub download.
- [ ] The Harbor push secret, the Gitea write-back secret, and the Cosign signing key exist on
      the disconnected cluster.
- [ ] The Tekton Dashboard is reachable at its internal address (TLS + DNS working).
- [ ] Gitea's allow-list includes the node address, and a push (or Test Delivery) returns a
      successful webhook response.
- [ ] A `Dockerfile` build works using only mirrored base images (BuildKit).
- [ ] A no-`Dockerfile` build works using only the mirrored builder and run image (Buildpacks).
- [ ] The pipeline signs the image and attests the SBOM using only the local Cosign key — no
      outside network calls.
- [ ] The CI commit to `helm-charts/values.yaml` does **not** start another pipeline run.
- [ ] Build logs show no public registry access at all.
---
 
## Troubleshooting
 
| What you see | What it usually means | What to do |
|---|---|---|
| `serviceaccount "gitea-trigger-sa" not found` | The permissions file was never applied | `kubectl get sa gitea-trigger-sa -n cicd`, then re-apply `gitea-trigger-rbac.yaml` (step 15) |
| `gitea-trigger-sa cannot list triggertemplates` (forbidden) | The Role or ClusterRole is missing something | Fix the roles, then re-run the `kubectl auth can-i` checks in step 15 |
| Gitea says *webhook can only call allowed HTTP servers*, or the delivery shows `Response 0` | Gitea blocked the request before sending it | Add the node IP to `GITEA__SECURITY__ALLOWED_HOST_LIST` (step 18) and check `app.ini` |
| `Connection refused` on the webhook URL | Wrong port — often an old NodePort, or the `9000` port instead of `8080` | Re-read the port with the `jsonpath` command in step 17 and update the Gitea webhook |
| Webhook returns `202` but no pipeline run appears | The filter, binding, or template rejected the event | Read `kubectl logs deployment/el-gitea-listener -n cicd`, dump the binding/template/listener with `-o yaml`, and compare the CEL filter against the real push message |
| The pipeline keeps triggering itself | The CI commit message doesn't start with the exact text the filter ignores | Make `update-values` and the EventListener filter use the same prefix: `ci: update TravelPortal image digest` |
| `update-values` fails with *fetch first* / *rejected* | A newer commit reached Gitea while the pipeline was running | Re-run the pipeline. Never use `git push --force` |
| `declared workspace "source" is required but has not been bound` | A Task in the Pipeline is missing its `source` workspace | Add `workspaces: [{ name: source, workspace: shared-workspace }]` to that Task (step 13) |
| `update-values` can't find `image-digest` | The `write-digest` step in the build Task is missing the line that saves the file | Compare the build Tasks with step 13 and re-apply them |
 
---
 
## Conclusion
 
Put simply: a developer pushes code to Gitea, and everything from that point on happens on its
own. Gitea tells Tekton, Tekton checks that the push is one it should act on, then checks
whether there's a `Dockerfile` and picks BuildKit or Buildpacks accordingly, builds the image,
writes down exactly what went into it, signs both the image and that record with Cosign, and
hands the finished, verified image to Harbor. Its last act is to write the new image's fixed ID
into the deployment file in Git — in a commit it knows to ignore — so ArgoCD can deploy it. The
same steps work identically whether the cluster is online or completely disconnected from the
internet, so there's one process to learn, trust, and audit, everywhere.
 
Before this goes live: replace every placeholder value (hostnames, node address, credentials,
namespaces, registry URLs, repository path, image versions) with your real environment's values,
generate and safely store your own Cosign key, and run through the air-gapped checklist even if
you're currently online — it's the easiest way to catch a missing mirror before it becomes a
production incident.
