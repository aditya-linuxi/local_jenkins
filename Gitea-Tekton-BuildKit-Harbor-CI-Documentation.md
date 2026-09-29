# Gitea → Tekton → BuildKit → Harbor
## Kubernetes-Based CI Pipeline Documentation

> **Purpose:** This document describes the CI pipeline implemented in the local Kubernetes/Minikube environment. The pipeline retrieves source code from **Gitea**, executes the CI workflow using **Tekton**, builds the application image using **BuildKit**, and pushes the resulting image to **Harbor**.

---

## 1. Executive Summary

The implemented CI process automates container image creation from application source code.

### End-to-end flow

```text
Developer / Git Repository
          |
          v
        Gitea
          |
          | Clone source code
          v
   Tekton Pipeline
          |
          v
   Shared Workspace
          |
          v
      BuildKit
          |
          | Dockerfile
          | Dependencies
          v
   Container Image
          |
          | Authenticate + Push
          v
       Harbor
          |
          v
 Image stored in registry
```

The main goal is to create a repeatable and Kubernetes-native CI process without requiring a traditional Docker daemon inside the CI worker.

---

# 2. Technologies Used

| Component | What it is | Why it is used |
|---|---|---|
| **Gitea** | Git repository platform | Stores and provides the application source code |
| **Kubernetes** | Container orchestration platform | Runs the CI components and build workloads |
| **Minikube** | Local Kubernetes environment | Used to develop and test the CI pipeline locally |
| **Tekton** | Kubernetes-native CI/CD framework | Defines and executes the CI workflow |
| **BuildKit** | Container image build engine | Builds the application image from the Dockerfile |
| **Harbor** | Private container registry | Stores and manages the built images |
| **kubectl** | Kubernetes CLI | Used to deploy and validate Kubernetes resources |

---

# 3. Why This Architecture Is Used

This architecture separates the responsibilities of source control, orchestration, image building, and image storage.

### Gitea
Gitea is responsible only for source-code management.

### Tekton
Tekton controls the workflow:

```text
Clone → Build → Push
```

### BuildKit
BuildKit is responsible for creating the OCI/container image.

### Harbor
Harbor is responsible for storing the final image and making it available for later deployment.

This separation makes the pipeline easier to maintain and allows each component to perform one specific responsibility.

---

# 4. CI Architecture

```text
                           +------------------+
                           |      Gitea       |
                           | Source Repository|
                           +--------+---------+
                                    |
                                    | Git clone
                                    v
                           +------------------+
                           | Tekton Pipeline  |
                           +--------+---------+
                                    |
                       +------------+------------+
                       |                         |
                       v                         v
                Clone Source Task         BuildKit Task
                       |                         |
                       +-----------+-------------+
                                   |
                                   v
                           Shared Workspace
                                   |
                                   v
                            Dockerfile + Code
                                   |
                                   v
                               BuildKit
                                   |
                                   v
                             Container Image
                                   |
                                   | Push
                                   v
                              +---------+
                              | Harbor  |
                              | Registry|
                              +---------+
```

---

# 5. Gitea

## What is Gitea?

Gitea is a lightweight Git service used to host source-code repositories.

In this CI implementation, Gitea is the source of truth for the application code.

The repository can contain:

```text
application/
├── Dockerfile
├── package.json
├── package-lock.json
├── src/
└── README.md
```

## Why Gitea is used

The pipeline needs a Git repository from which it can retrieve the application source code.

The Tekton clone task receives the Gitea repository URL as a parameter.

Example:

```yaml
params:
  - name: repo-url
    value: "https://<gitea-host>/<owner>/<repository>.git"
```

> Replace the placeholder with the actual repository URL used in the environment.

---

# 6. Kubernetes / Minikube

## What is Minikube?

Minikube runs a local Kubernetes cluster for development and testing.

It provides the Kubernetes environment in which the Tekton and BuildKit workloads run.

Typical validation:

```bash
kubectl get nodes
```

Expected result:

```text
NAME       STATUS   ROLES           AGE
minikube   Ready    control-plane   ...
```

## Why Minikube is used

Minikube allows the complete CI flow to be tested locally before moving the configuration to a larger Kubernetes or VKS environment.

The same general Kubernetes concepts are used:

- Pods
- Services
- Secrets
- Persistent storage
- ServiceAccounts
- Tasks
- Pipelines
- PipelineRuns
- TaskRuns

---

# 7. Tekton

## What is Tekton?

Tekton is a Kubernetes-native framework for creating CI/CD pipelines.

Tekton represents CI workflow components as Kubernetes resources.

Important Tekton resources used in this implementation:

### Task

A `Task` defines a unit of work.

Examples:

```text
clone-source
build-image
push-image
```

### Pipeline

A `Pipeline` defines how the Tasks are connected.

Example:

```text
clone-source
      |
      v
build-image
      |
      v
push-image
```

### TaskRun

A `TaskRun` is one execution of a Task.

### PipelineRun

A `PipelineRun` is one execution of a Pipeline.

### Workspace

A Workspace provides storage that can be shared between Tasks.

### Parameters

Parameters make the Pipeline reusable.

---

# 8. Tekton CI Workflow

The implemented workflow is conceptually:

```text
PipelineRun
    |
    v
Clone source from Gitea
    |
    v
Store source in shared workspace
    |
    v
Run BuildKit
    |
    v
Build image from Dockerfile
    |
    v
Authenticate to Harbor
    |
    v
Push image to Harbor
```

Each stage must complete successfully before the next dependent stage is executed.

---

# 9. Source Clone Stage

The clone Task downloads source code from Gitea.

Example concept:

```yaml
params:
  - name: repo-url
    value: "https://<gitea-host>/<owner>/<repository>.git"

workspaces:
  - name: source
```

The cloned source is written into the Tekton Workspace.

The BuildKit task then uses the same workspace as its build context.

## Validation

Check the TaskRun:

```bash
kubectl get taskruns -n <namespace>
```

Check logs:

```bash
kubectl logs -n <namespace> <pod-name>
```

The clone stage is successful when the repository is downloaded without Git or network errors.

---

# 10. Shared Workspace

The Workspace connects the clone stage and the build stage.

```text
Clone Task
    |
    | writes source
    v
+----------------------+
| Tekton Workspace     |
|                      |
| Dockerfile           |
| package files        |
| application source   |
+----------+-----------+
           |
           | read as build context
           v
      BuildKit Task
```

Without shared storage, the second Task would not automatically have the source code downloaded by the first Task.

The Workspace therefore acts as the hand-off point between pipeline stages.

---

# 11. Dockerfile and Build Context

BuildKit needs two main things:

1. A Dockerfile.
2. A build context.

Example:

```text
/workspace/source/
├── Dockerfile
├── package.json
├── package-lock.json
└── src/
```

The Dockerfile defines how the image is built.

Example:

```dockerfile
FROM node:22-alpine

WORKDIR /app

COPY package*.json ./

RUN npm install

COPY . .

EXPOSE 3000

CMD ["npm", "start"]
```

---

# 12. BuildKit

## What is BuildKit?

BuildKit is a modern container image build engine.

It processes the Dockerfile and generates the final image.

For example:

```text
Dockerfile
    +
Application source
    +
Base image
    +
Dependencies
    |
    v
  BuildKit
    |
    v
Container image
```

## Why BuildKit is used

BuildKit is used because it provides a modern image-building mechanism and does not require the CI process to depend on a traditional Docker-in-Docker daemon.

Important BuildKit capabilities include:

- Dockerfile builds
- Layered image construction
- Build caching
- Registry integration
- Efficient build execution

---

# 13. BuildKit Build Process

During the build, BuildKit may perform operations such as:

```text
1. Read Dockerfile
2. Resolve FROM image
3. Download base image
4. Execute RUN instructions
5. Copy application files
6. Create image layers
7. Generate final image
8. Tag image
9. Push image to Harbor
```

Example:

```text
FROM node:22-alpine
        |
        v
Download base image
        |
        v
RUN npm install
        |
        v
Copy application source
        |
        v
Final image
```

---

# 14. Dependency Installation

Dependencies are installed during the Docker build.

For a Node.js application:

```dockerfile
RUN npm install
```

The command downloads packages from the configured npm registry.

For Alpine Linux:

```dockerfile
RUN apk add --no-cache <package>
```

For Python:

```dockerfile
RUN pip install -r requirements.txt
```

All of these operations may require outbound HTTPS connectivity.

---

# 15. SSL/TLS Considerations

A major troubleshooting area in the local CI environment was HTTPS access during image builds.

There are multiple HTTPS connections involved:

```text
                 +----------------------+
                 |       BuildKit       |
                 +----------+-----------+
                            |
             +--------------+--------------+
             |                             |
             v                             v
      Container Registry          Dependency Registry
       (base image)                 (npm/apk/pip)
```

Therefore, a successful connection from the Minikube node does not always prove that the BuildKit build container can access the same HTTPS endpoints successfully.

## Possible causes of HTTPS failures

- Missing CA certificates
- Expired certificates
- Untrusted certificate authority
- Company TLS inspection
- Proxy configuration
- DNS problems
- Firewall restrictions
- Incorrect system time
- Private registry CA not trusted by BuildKit

---

# 16. CA Certificates

For a normal public HTTPS endpoint, the container should have an up-to-date CA bundle.

Example Alpine Dockerfile:

```dockerfile
FROM node:22-alpine

RUN apk add --no-cache ca-certificates && \
    update-ca-certificates

WORKDIR /app

COPY package*.json ./

RUN npm install

COPY . .

CMD ["npm", "start"]
```

### Important

If this command itself fails:

```dockerfile
RUN apk add --no-cache ca-certificates
```

then the problem may be occurring before the CA package can be installed.

In that case, investigate:

- Network access
- DNS
- Proxy
- Certificate trust
- Company root CA

Do not simply disable certificate verification.

Avoid:

```bash
curl -k ...
```

or:

```bash
npm config set strict-ssl false
```

These bypass TLS verification and are not appropriate as a permanent CI solution.

---

# 17. Private Registry / Harbor TLS

Harbor may use:

- Public CA certificate
- Internal CA certificate
- Self-signed certificate
- HTTP in a local lab

If Harbor uses an internal/private CA, the BuildKit environment must trust the corresponding CA certificate.

BuildKit also provides registry-specific configuration for custom certificate authorities.

Conceptually:

```toml
[registry."harbor.example"]
  ca=["/etc/certs/harbor-ca.pem"]
```

The exact configuration depends on how BuildKit is deployed.

---

# 18. Harbor

## What is Harbor?

Harbor is a private OCI/container image registry.

It stores the image generated by the CI pipeline.

Example image reference:

```text
<harbor-host>/<project>/<image>:<tag>
```

Example:

```text
192.168.49.2:30002/library/my-app:build-001
```

> Use the actual Harbor host, port, project, image name, and tag from the environment.

## Why Harbor is used

Harbor provides a central private registry for container images.

It can provide capabilities such as:

- Repository management
- Access control
- Image versioning
- Vulnerability scanning
- Image replication
- Project-level permissions
- Image retention policies

---

# 19. Harbor Authentication

The CI pipeline needs credentials to push an image.

Credentials should be stored in a Kubernetes Secret.

Example:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: harbor-registry-secret
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: <encoded-docker-config>
```

The secret should be referenced by the appropriate ServiceAccount or task configuration.

## Security rule

Never place:

```text
username
password
token
```

directly inside a committed Pipeline YAML file.

Use Kubernetes Secrets or an approved external secret-management solution.

---

# 20. Image Naming and Tagging

A complete Harbor image reference normally contains:

```text
REGISTRY/PROJECT/IMAGE:TAG
```

Example:

```text
harbor.example.com/library/travel-portal:build-001
```

For CI, unique tags are preferable to using only `latest`.

Examples:

```text
travel-portal:build-101
travel-portal:2026-09-13
travel-portal:<git-commit-sha>
```

A Git commit SHA is particularly useful because it allows an image to be traced back to the source revision that produced it.

---

# 21. Complete CI Execution

The complete process is:

### 1. Start PipelineRun

```bash
kubectl apply -f pipelinerun.yaml
```

### 2. Tekton starts the clone Task

```text
Gitea → Workspace
```

### 3. Source is validated

```text
Dockerfile exists
Source files exist
```

### 4. BuildKit starts

```text
Workspace → BuildKit
```

### 5. BuildKit creates the image

```text
Dockerfile
   +
Base image
   +
Dependencies
   +
Source
   ↓
Container image
```

### 6. BuildKit authenticates to Harbor

```text
Kubernetes Secret → Harbor credentials
```

### 7. Image is pushed

```text
BuildKit → Harbor
```

### 8. Image is validated

```text
Harbor repository
        |
        v
Image tag
        |
        v
Image digest
```

---

# 22. Validation and Verification

Successful pipeline status alone is not enough.

The following should be validated.

## 22.1 Kubernetes Cluster

```bash
kubectl cluster-info
```

```bash
kubectl get nodes -o wide
```

Expected:

```text
STATUS = Ready
```

---

## 22.2 Tekton Resources

```bash
kubectl get tasks -A
```

```bash
kubectl get pipelines -A
```

```bash
kubectl get taskruns -A
```

```bash
kubectl get pipelineruns -A
```

---

## 22.3 PipelineRun

```bash
kubectl get pipelinerun <run-name> -n <namespace>
```

Detailed information:

```bash
kubectl describe pipelinerun <run-name> -n <namespace>
```

The final condition should indicate success.

---

## 22.4 TaskRun Validation

```bash
kubectl get taskruns -n <namespace>
```

Check each TaskRun:

```bash
kubectl describe taskrun <taskrun-name> -n <namespace>
```

Verify that:

- Clone Task succeeded.
- BuildKit Task succeeded.
- Push operation succeeded.

---

## 22.5 Pipeline Logs

If Tekton CLI is installed:

```bash
tkn pipelinerun logs <run-name> -n <namespace> -f
```

Otherwise:

```bash
kubectl logs -n <namespace> <pod-name>
```

Check for:

```text
clone successful
build successful
push successful
```

---

# 23. Gitea Validation

Verify repository access:

```bash
git ls-remote <gitea-repository-url>
```

Verify the expected commit:

```bash
git rev-parse --short HEAD
```

The commit that is built should match the intended source revision.

This is important for build traceability.

---

# 24. Dockerfile Validation

Before running the pipeline:

```bash
test -f Dockerfile
```

or:

```bash
ls -la
```

Confirm that the Dockerfile is located in the build context expected by BuildKit.

---

# 25. BuildKit Validation

Check the BuildKit task logs and confirm:

```text
Dockerfile found
Base image resolved
Dependencies downloaded
Build steps completed
Final image generated
```

If the build fails during dependency installation, identify whether the failure is:

```text
DNS
Network
Proxy
TLS
CA
Registry
Package manager
```

Do not assume every dependency failure is a BuildKit issue.

---

# 26. Harbor Validation

After the pipeline succeeds, verify the image in Harbor.

Check:

```text
Harbor
  → Project
    → Repository
      → Image
        → Tag
```

Confirm:

- Repository exists.
- Expected tag exists.
- Image digest is present.
- Image size is reasonable.
- Image scan status is available if scanning is enabled.

---

# 27. Pull Validation

The final validation should also verify that the created image can be pulled.

Example:

```bash
docker pull <harbor-host>/<project>/<image>:<tag>
```

If Harbor uses HTTPS with an internal CA, the client performing this command must trust the Harbor CA.

---

# 28. Troubleshooting

## Problem: Gitea clone fails

Possible causes:

- Incorrect repository URL
- Authentication failure
- DNS failure
- Network connectivity
- TLS certificate problem

Check:

```bash
git ls-remote <gitea-url>
```

---

## Problem: Dockerfile not found

Possible causes:

- Wrong workspace path
- Wrong build context
- Dockerfile has a different name
- Source was cloned into an unexpected directory

Validate:

```bash
find /workspace -name Dockerfile -print
```

---

## Problem: Dependency download fails over HTTPS

Possible causes:

- Missing CA certificate
- Company proxy
- TLS interception
- Certificate expiration
- DNS failure
- Firewall

Test from the same build environment rather than testing only from the host.

---

## Problem: Harbor push denied

Possible causes:

- Incorrect credentials
- Secret not mounted
- Wrong Harbor project
- Insufficient Harbor permissions

Check:

```bash
kubectl get secret -n <namespace>
```

Do not print the secret contents.

---

## Problem: Harbor TLS error

Possible causes:

- Harbor certificate not trusted
- Private CA missing
- Wrong registry endpoint
- Certificate hostname mismatch

Install/configure the correct CA in the environment that connects to Harbor.

---

## Problem: TaskRun remains Pending

Check:

```bash
kubectl describe taskrun <taskrun> -n <namespace>
```

Then inspect the generated Pod:

```bash
kubectl get pods -n <namespace>
```

Possible causes:

- Insufficient CPU/memory
- PVC problem
- Scheduling issue
- ServiceAccount problem
- Security policy restriction

---

# 29. Pod Security Admission Considerations

Kubernetes Pod Security Admission can restrict what Tekton and BuildKit Pods are allowed to do.

Before deploying to a VKS or production-like cluster, verify:

```bash
kubectl get namespace <namespace> --show-labels
```

Review:

- `enforce`
- `audit`
- `warn`

Do not simply change the namespace to `privileged` to make errors disappear.

Instead, identify the exact security requirement of the BuildKit workload and apply the least-permissive policy that supports the build.

---

# 30. Security Best Practices

### Credentials

Use Kubernetes Secrets for:

- Harbor username/password
- Registry tokens
- Private Git credentials

### TLS

Prefer HTTPS and valid trusted certificates.

Do not permanently disable TLS verification.

### Image Tags

Prefer immutable or unique tags.

### Base Images

Use trusted, maintained base images.

For stronger reproducibility, pin important base images by digest.

### Access Control

Use least-privilege ServiceAccounts and Harbor permissions.

### Logs

Make sure credentials are not printed in Task logs.

### Image Scanning

Enable Harbor vulnerability scanning where available.

---

# 31. Production Migration Considerations

The Minikube implementation is a local validation environment.

Before moving the same architecture to VKS or another production Kubernetes cluster, validate:

## Network

```text
Gitea → Kubernetes Pods
Kubernetes Pods → Harbor
Kubernetes Pods → required dependency registries
```

## Certificates

Ensure all required CAs are trusted by:

- Git clone environment
- BuildKit environment
- Base images
- Harbor clients
- Dependency managers

## Storage

Verify:

- Workspace PVC capacity
- Build cache capacity
- Access modes
- Cleanup policies

## Security

Verify:

- ServiceAccount permissions
- Harbor RBAC
- Kubernetes RBAC
- Pod Security Admission
- Secret management

## Reliability

Plan for:

- Build failures
- Registry outages
- Retry behavior
- Image retention
- Rollback
- Build cache cleanup

---

# 32. Recommended Validation Checklist

Use this checklist after every major configuration change.

```text
[ ] Minikube/Kubernetes node is Ready
[ ] Tekton controllers are Running
[ ] Gitea repository is reachable
[ ] Clone Task succeeds
[ ] Source appears in Workspace
[ ] Dockerfile exists
[ ] BuildKit starts successfully
[ ] Base image can be pulled
[ ] Dependencies can be downloaded
[ ] HTTPS/TLS validation succeeds
[ ] Image is created successfully
[ ] Harbor credentials are available
[ ] Harbor authentication succeeds
[ ] Image is pushed successfully
[ ] Image tag exists in Harbor
[ ] Image digest exists
[ ] Image can be pulled
[ ] No credentials are exposed in logs
```

---

# 33. Final CI Flow

```text
                    +----------------+
                    |     Gitea      |
                    | Git Repository |
                    +-------+--------+
                            |
                            | Clone
                            v
                    +---------------+
                    |     Tekton    |
                    |    Pipeline   |
                    +-------+-------+
                            |
                            v
                    +---------------+
                    | Shared        |
                    | Workspace     |
                    +-------+-------+
                            |
                            v
                    +---------------+
                    |    BuildKit   |
                    | Dockerfile    |
                    | Build         |
                    +-------+-------+
                            |
                            v
                    +---------------+
                    | Container     |
                    | Image         |
                    +-------+-------+
                            |
                            | Push
                            v
                    +---------------+
                    |    Harbor     |
                    | Image Registry|
                    +---------------+
```

---

# 34. Conclusion

The implemented CI architecture provides a Kubernetes-native flow for converting source code from Gitea into a container image and storing that image in Harbor.

The responsibilities are clearly separated:

```text
Gitea    = Source Code
Tekton   = CI Workflow
BuildKit = Image Build
Harbor   = Image Registry
```

The complete process is:

```text
Gitea
  ↓
Tekton Clone
  ↓
Shared Workspace
  ↓
BuildKit
  ↓
Container Image
  ↓
Harbor Push
  ↓
Harbor Validation
```

The most important part of CI validation is to verify the **entire chain**, not only the final PipelineRun status.

A successful implementation should prove that the correct source revision was cloned, the Dockerfile was built successfully, dependencies were downloaded securely, the image was pushed to the correct Harbor repository, and the resulting image can be retrieved for deployment.
