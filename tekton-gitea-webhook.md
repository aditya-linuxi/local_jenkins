# Tekton + Gitea Webhook CI Implimentation

## 1. Purpose

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
   |      +--> optional CI/self-trigger filter
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

> **Reading this runbook:** Each command has a short **What / Why / How** note immediately before it. Each YAML block has a matching explanation, kept to five lines or fewer.

---

# 2. Lab-specific values

## Kubernetes

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

---

# 3. Tekton Triggers components

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

# 4. Tekton Triggers CRDs and controller validation

Check that Triggers is installed:

What: Checks that the Tekton Triggers CRDs are installed.
Why: EventListener and trigger objects depend on these CRDs.
How: Run it on the jumpbox and confirm the Triggers resource names appear.

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

What: Lists the Tekton system pods.
Why: The Triggers controller, interceptors, and webhook must be running before the listener can work.
How: Look for the expected `tekton-triggers-*` pods.

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

What: Lists Triggers-related Deployments.
Why: Confirms the controller components are deployed.
How: `grep triggers` keeps the output focused on Tekton Triggers.

```bash
kubectl get deployment -n tekton-pipelines | grep triggers
```

---

# 5. EventListener ServiceAccount and RBAC

The EventListener runs with:

What: Sets the EventListener to use `github-trigger-sa`.
Why: Gives the listener a specific Kubernetes identity for RBAC.
How: The name must match the ServiceAccount created in the RBAC section.

```yaml
serviceAccountName: github-trigger-sa
```

## 5.1 ServiceAccount

What: Creates the `github-trigger-sa` ServiceAccount in `cicd`.
Why: Gives the EventListener a dedicated identity.
How: The EventListener references this exact name under `serviceAccountName`.

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: github-trigger-sa
  namespace: cicd
```

## 5.2 Namespace Role

The EventListener needs permission to read the Triggers resources in `cicd` and create PipelineRuns.

What: Grants namespace-scoped access to Triggers resources and PipelineRuns.
Why: The listener must read trigger configuration and create PipelineRuns.
How: The Role is limited to namespace `cicd`.

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

## 5.3 RoleBinding

What: Binds `github-trigger-sa` to `github-trigger-role`.
Why: A Role grants no permissions until a subject is bound to it.
How: `subjects` names the ServiceAccount and `roleRef` names the Role.

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

## 5.4 ClusterRole

These Triggers resources are cluster-scoped:

```text
clusterinterceptors
clustertriggerbindings
```

Therefore a ClusterRole is required.

What: Grants read access to cluster-scoped Trigger resources.
Why: `clusterinterceptors` and `clustertriggerbindings` are not namespaced.
How: Pair this ClusterRole with the ClusterRoleBinding below.

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

## 5.5 ClusterRoleBinding

What: Binds `github-trigger-sa` to the cluster-scoped Triggers role.
Why: Without this binding, cluster-scoped resources can still return `forbidden`.
How: The ServiceAccount is namespaced but may be bound to a ClusterRole.

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

What: Applies the complete EventListener RBAC file.
Why: The listener needs these permissions to inspect Trigger resources and create PipelineRuns.
How: Keep all five RBAC objects in the same YAML file for repeatable setup.

```bash
kubectl apply -f github-trigger-rbac.yaml
```

Validate:

What: Verifies the ServiceAccount, Role, RoleBinding, ClusterRole, and ClusterRoleBinding exist.
Why: A missing object can prevent the EventListener from starting.
How: Run after applying the RBAC YAML and check each command returns an object.

```bash
kubectl get sa github-trigger-sa -n cicd
kubectl get role github-trigger-role -n cicd
kubectl get rolebinding github-trigger-rolebinding -n cicd
kubectl get clusterrole github-trigger-cluster-role
kubectl get clusterrolebinding github-trigger-cluster-rolebinding
```

Validate permissions:

What: Tests the exact Kubernetes permissions used by `github-trigger-sa`.
Why: A `yes` result proves the RBAC is effective, not just that the YAML exists.
How: Every requested permission should return `yes`.

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

# 6. Gitea outbound webhook security

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

## 6.1 Working Helm override

Use `additionalConfigFromEnvs`:

What: Defines the Gitea Helm override for `ALLOWED_HOST_LIST`.
Why: Gitea must permit outbound webhook calls to the Tekton node IP.
How: The chart maps the environment variable into Gitea's `[security]` configuration.

```yaml
gitea:
  additionalConfigFromEnvs:
    - name: GITEA__SECURITY__ALLOWED_HOST_LIST
      value: "10.12.90.62,10.12.92.3"
```

Create:

What: Creates the temporary Helm override file for Gitea webhook security.
Why: Gitea must receive `ALLOWED_HOST_LIST` in a form that renders into `app.ini`.
How: The file allows the Gitea and Kubernetes node IPs used by this lab.

```bash
cat >/tmp/gitea-webhook-values.yaml <<'EOF'
gitea:
  additionalConfigFromEnvs:
    - name: GITEA__SECURITY__ALLOWED_HOST_LIST
      value: "10.12.90.62,10.12.92.3"
EOF
```

Use `--reuse-values` so existing Helm values are preserved:

What: Reconciles the existing Gitea Helm release with the webhook allow-list override.
Why: Gitea must be allowed to call the Tekton NodePort IP.
How: `--reuse-values` preserves existing lab settings while `-f` adds this change.

```bash
helm upgrade gitea gitea-charts/gitea \
  -n gitea \
  --version 12.7.0 \
  --reuse-values \
  -f /tmp/gitea-webhook-values.yaml
```

Validate:

What: Waits until the updated Gitea Deployment is ready.
Why: Validate the new webhook setting only after the rollout completes.
How: The command exits successfully when the Deployment is rolled out.

```bash
kubectl rollout status deployment/gitea -n gitea
```

Then:

What: Runs the check or change shown below.
Why: It validates or applies the configuration in this section.
How: Run it from a machine with the required Kubernetes, Helm, or Git access.

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

# 7. TriggerBinding

The TriggerBinding extracts information from the Gitea JSON payload.

For this lab the repository URL is fixed, which is intentional. This prevents differences between GitHub/Gitea payload field names from affecting the repository parameter.

What: Maps Gitea webhook JSON fields into trigger parameters.
Why: The Template needs the repository, branch, commit message, and SHA.
How: `$(body...)` expressions are evaluated when the event arrives.

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

What: Creates or updates the TriggerBinding.
Why: It maps Gitea payload fields into named trigger parameters.
How: Apply it before creating the EventListener so the referenced binding exists.

```bash
kubectl apply -f triggerbinding.yaml
```

Validate:

What: Dumps the TriggerBinding, TriggerTemplate, and EventListener objects together.
Why: These three resources form the trigger chain.
How: Compare names, references, branch filter, params, and template settings.

```bash
kubectl get triggerbinding travelportal-github-binding -n cicd -o yaml
```

The important values must be:

```text
REPO_URL = http://10.12.90.62/admin/travelPortal-test-buildpack.git
REVISION = main
```

---

# 8. TriggerTemplate

The TriggerTemplate creates the PipelineRun.

Working structure:

What: Defines the PipelineRun created after a webhook is accepted.
Why: Keeps event parsing separate from Pipeline execution settings.
How: `pipelineRef`, params, TaskRun settings, and workspaces recreate the working CI run.

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

What: Creates or updates the TriggerTemplate.
Why: It defines the PipelineRun created when a webhook is accepted.
How: Apply after the Pipeline and workspace names are already present.

```bash
kubectl apply -f triggertemplate.yaml
```

Validate:

What: Prints the live TriggerTemplate definition.
Why: Confirms the pipeline name, parameters, secret, and PVC references are correct.
How: Inspect `pipelineRef`, params, `taskRunSpecs`, and workspaces.

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

# 9. EventListener

The current EventListener intentionally retains its historical name `travelportal-github-listener`, but it is used by Gitea.

## Working NodePort configuration

What: Defines the HTTP EventListener and its trigger chain.
Why: Gitea needs a reachable endpoint that can filter events and launch a PipelineRun.
How: NodePort exposes it; CEL filters; Binding supplies values; Template creates the run.

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
                body.ref == 'refs/heads/main'

      bindings:
        - ref: travelportal-github-binding

      template:
        ref: travelportal-github-template
```

Apply:

What: Creates or updates the HTTP EventListener.
Why: This is the webhook entry point for Gitea.
How: It connects NodePort exposure, CEL filtering, TriggerBinding, and TriggerTemplate.

```bash
kubectl apply -f eventlistener.yaml
```

Validate:

What: Checks EventListener readiness.
Why: Gitea needs a ready listener before webhook delivery can work.
How: Look for `AVAILABLE=True` and `READY=True`.

```bash
kubectl get eventlistener travelportal-github-listener -n cicd
```

Expected:

```text
AVAILABLE=True
READY=True
```

Check the generated Service:

What: Shows the Service and the real NodePort allocated to the EventListener.
Why: The generated port is authoritative and prevents using an old port such as 31878.
How: Use the `8080:<nodePort>` mapping for the webhook URL.

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

# 10. EventListener connectivity validation

First validate the Service endpoints:

What: Checks that the Service has a live EventListener backend.
Why: A NodePort with no endpoint cannot deliver requests to the listener.
How: Confirm the endpoint includes port `8080`.

```bash
kubectl get endpoints el-travelportal-github-listener -n cicd -o wide
```

Expected to contain the EventListener pod on:

```text
:8080
```

Check the pod:

What: Finds the EventListener pod and its node.
Why: Helps separate pod placement issues from Service or network problems.
How: The label selects only the EventListener pods.

```bash
kubectl get pods -n cicd \
  -l eventlistener=travelportal-github-listener \
  -o wide
```

Test the NodePort:

What: Sends a basic HTTP request to the EventListener NodePort.
Why: Separates Kubernetes/network problems from Gitea webhook security.
How: A reachable listener should return an HTTP response rather than `Connection refused`.

```bash
curl -v http://10.12.92.3:31877
```

A direct webhook-style POST test:

What: Creates a small local push-event JSON file.
Why: Gives you a repeatable payload for direct webhook testing.
How: Its fields match the values read by the TriggerBinding and CEL filter.

```bash
cat >/tmp/test-event.json <<'EOF'
{
  "ref": "refs/heads/main",
  "after": "test-sha",
  "head_commit": {
    "message": "test webhook"
  }
}
EOF
```

Then:

What: Posts the test JSON to the EventListener as `application/json`.
Why: Confirms Tekton accepts the event before relying on Gitea delivery.
How: `HTTP/1.1 202 Accepted` means the listener accepted the request.

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

# 11. Gitea repository webhook

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

---

# 12. Expected Gitea webhook payload

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
  }
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

# 13. Pipeline behavior after a developer push

Developer:

What: Creates and pushes a real developer commit.
Why: Exercises the complete Gitea-to-Tekton trigger path.
How: Run from the TravelPortal repository on branch `main`.

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
  | body.ref == refs/heads/main
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

What: Lists PipelineRuns in `cicd`.
Why: Confirms whether a webhook created a `travelportal-build-*` run.
How: Run immediately after a real push or Test Delivery.

```bash
kubectl get pipelineruns -n cicd
```

Watch live:

What: Watches PipelineRuns as they change state.
Why: Lets you follow the triggered build through completion.
How: Stop watching with `Ctrl+C` after the run reaches a terminal state.

```bash
kubectl get pipelineruns -n cicd -w
```

---

# 14. Pipeline flow

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

# 15. BuildKit digest result

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

The digest is passed to the signing/update stages through the Tekton result.

---

# 16. Buildpacks digest result

The Buildpacks task reads:

```text
/layers/report.toml
```

and writes:

```text
$(results.APP_IMAGE_DIGEST.path)
```

The digest must be exposed as the Buildpacks Task result.

The Pipeline should make the signing/update stage consume the digest from the branch that actually executed.

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

# 17. Sign stage

The signing Task runs after either BuildKit or Buildpacks.

It generates an SBOM using Syft and signs the image with Cosign.

Required secrets used by the sign task:

```text
harbor-credentials
cosign-password
cosign-key
harbor-registry-secret
```

The sign Task must have every workspace that it references.

For example, if the task reads:

```text
$(workspaces.source.path)/image-digest
```

then the Pipeline Task must bind:

What: Binds the sign Task's `source` workspace to the Pipeline's source workspace.
Why: The sign step reads the normalized image digest from that workspace.
How: The Task workspace name must match the Pipeline binding exactly.

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

# 18. Update-values Task

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

## Git credentials

Create a dedicated Gitea token and Kubernetes Secret:

What: Stores the Gitea username and token in a Kubernetes Secret.
Why: The update-values Task needs write access without embedding a token in YAML.
How: Replace `<GITEA_TOKEN>` with a Gitea Personal Access Token.

```bash
kubectl create secret generic gitea-git-credentials \
  -n cicd \
  --from-literal=username=admin \
  --from-literal=token='<GITEA_TOKEN>'
```

Do not put the token directly in Pipeline YAML.

The Task should reference:

What: Defines the configuration fragment shown below.
Why: It supplies one setting used by the webhook or Pipeline flow.
How: Keep its names consistent with the objects and workspaces referenced elsewhere.

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

## Gitea remote

Do not hard-code GitHub.

Use the Pipeline parameter:

What: Builds the authenticated Git remote from the Pipeline parameter.
Why: Prevents the CI task from pushing to the old GitHub URL.
How: Strip `http://` or `https://`, then set the Gitea remote with the Secret credentials.

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

# 19. Git non-fast-forward handling

A CI push can fail with:

```text
! [rejected] main -> main (fetch first)
Updates were rejected because the remote contains work that you do not have locally.
```

This happens when another commit reached Gitea after the Task cloned the repository.

Do NOT solve this with:

**What this command block does:** Builds the authenticated Gitea URL from `$(params.REPO_URL)` and sets it as the Git remote. **Why:** This removes the old GitHub hard-code and directs CI writes to the internal Gitea server.

What: Shows a force-push command only as a warning.
Why it is unsafe: It can overwrite newer developer commits.
How: Do not use it; use the fetch/reset recovery path instead.

```bash
git push --force
```

For a safer implementation:

**What this command shows:** An example of the unsafe force-push workaround. **Why it is shown:** It documents what not to do when the remote has newer commits.

What: Fetches the latest remote `main` and resets the local clone to it.
Why: Prevents non-fast-forward failures when another commit arrived meanwhile.
How: Reapply the intended `values.yaml` edit after the reset, then commit and push.

```bash
git fetch origin main
git reset --hard origin/main
```

then re-apply the `values.yaml` change, commit, and push.

This protects developer commits from being overwritten.

---

# 20. The CI feedback loop problem

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

# 21. Recommended self-trigger prevention

Use a clearly identifiable CI commit message.

In `update-values`:

What: Creates the CI commit with the fixed message prefix.
Why: The message can be recognized by the self-trigger CEL filter.
How: Keep the prefix exactly as shown if using the message-based rule.

```bash
git commit -m "ci: update TravelPortal image digest"
```

Then use a CEL filter:

What: Filters out the CI-generated commit message prefix.
Why: Prevents `update-values` from triggering the same pipeline again.
How: The CI commit message must start with the exact configured prefix.

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
          !body.head_commit.message.startsWith('ci: update TravelPortal image digest')
```

Important:

The commit message produced by `update-values` MUST start with exactly:

```text
ci: update TravelPortal image digest
```

Otherwise the filter will not reject the CI commit.

---

# 22. Stronger self-trigger prevention

For a stronger rule, filter based on the actual files changed by the webhook.

The CI commit only changes:

```text
helm-charts/values.yaml
```

A developer application commit normally changes something such as:

```text
Dockerfile
main.go
go.mod
web/...
```

A stronger CEL rule can be based on the Gitea payload's `commits[].added`, `commits[].modified`, and `commits[].removed` fields.

Example pattern:

What: Filters events using the actual files changed in the Gitea payload.
Why: It can reject a CI commit that only changes `helm-charts/values.yaml`.
How: Validate the expression against an actual Gitea delivery before using it as the final filter.

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

This is preferred when the webhook payload contains the expected `commits[].added`, `modified`, and `removed` arrays.

Validate with an actual Gitea webhook delivery before treating this rule as final.

---

# 23. `.gitignore` is NOT the solution

Do not add:

```text
helm-charts/values.yaml
```

to `.gitignore`.

The file is already tracked by Git.

`.gitignore` does not prevent changes to an already-tracked file from being committed.

The feedback loop must be controlled at the trigger/filter level.

---

# 24. End-to-end validation checklist

## Triggers installed

What: Checks that the Tekton Triggers CRDs are installed.
Why: EventListener and trigger objects depend on these CRDs.
How: Run it on the jumpbox and confirm the Triggers resource names appear.

```bash
kubectl get crd | grep triggers.tekton.dev
```

## Trigger controller healthy

What: Runs the check or change shown below.
Why: It validates or applies the configuration in this section.
How: Run it from a machine with the required Kubernetes, Helm, or Git access.

```bash
kubectl get pods -n tekton-pipelines | grep triggers
```

## ServiceAccount

What: Verifies the ServiceAccount, Role, RoleBinding, ClusterRole, and ClusterRoleBinding exist.
Why: A missing object can prevent the EventListener from starting.
How: Run after applying the RBAC YAML and check each command returns an object.

```bash
kubectl get sa github-trigger-sa -n cicd
```

## RBAC

What: Runs the check or change shown below.
Why: It validates or applies the configuration in this section.
How: Run it from a machine with the required Kubernetes, Helm, or Git access.

```bash
kubectl get role github-trigger-role -n cicd
kubectl get rolebinding github-trigger-rolebinding -n cicd
kubectl get clusterrole github-trigger-cluster-role
kubectl get clusterrolebinding github-trigger-cluster-rolebinding
```

## EventListener

What: Checks EventListener readiness.
Why: Gitea needs a ready listener before webhook delivery can work.
How: Look for `AVAILABLE=True` and `READY=True`.

```bash
kubectl get eventlistener travelportal-github-listener -n cicd
```

Expected:

```text
AVAILABLE=True
READY=True
```

## NodePort

What: Shows the Service and the real NodePort allocated to the EventListener.
Why: The generated port is authoritative and prevents using an old port such as 31878.
How: Use the `8080:<nodePort>` mapping for the webhook URL.

```bash
kubectl get svc el-travelportal-github-listener -n cicd
```

Expected:

```text
8080:31877/TCP
```

## Endpoint

What: Checks that the Service has a live EventListener backend.
Why: A NodePort with no endpoint cannot deliver requests to the listener.
How: Confirm the endpoint includes port `8080`.

```bash
kubectl get endpoints el-travelportal-github-listener -n cicd
```

Expected an endpoint on:

```text
:8080
```

## Direct webhook test

What: Posts the test JSON to the EventListener as `application/json`.
Why: Confirms Tekton accepts the event before relying on Gitea delivery.
How: `HTTP/1.1 202 Accepted` means the listener accepted the request.

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

## TriggerBinding

What: Displays the TriggerBinding stored in Kubernetes.
Why: Confirms the repository URL and branch before webhook testing.
How: Compare `REPO_URL` with the internal Gitea URL and `REVISION` with `main`.

```bash
kubectl get triggerbinding travelportal-github-binding -n cicd
```

## TriggerTemplate

What: Confirms the TriggerTemplate exists.
Why: The EventListener references this object when creating PipelineRuns.
How: A successful result means Kubernetes can resolve the template by name.

```bash
kubectl get triggertemplate travelportal-github-template -n cicd
```

## Pipeline exists

What: Confirms the TravelPortal Pipeline exists.
Why: The TriggerTemplate cannot create a valid PipelineRun if this reference is missing.
How: The expected name is `travelportal-pipeline-values-update`.

```bash
kubectl get pipeline travelportal-pipeline-values-update -n cicd
```

## Gitea outbound allow-list

What: Reads the live Gitea `app.ini` security section.
Why: Confirms the Helm setting reached the running container.
How: Look for `ALLOWED_HOST_LIST = 10.12.90.62,10.12.92.3`.

```bash
kubectl exec -n gitea deployment/gitea -- \
  grep -n 'ALLOWED_HOST_LIST' /data/gitea/conf/app.ini
```

Expected:

```text
ALLOWED_HOST_LIST = 10.12.90.62,10.12.92.3
```

## Gitea webhook

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

## Watch the EventListener

What: Follows EventListener logs in real time.
Why: Shows webhook receipt, CEL decisions, and trigger errors.
How: Start it before a Test Delivery, then stop with `Ctrl+C`.

```bash
kubectl logs -f deployment/el-travelportal-github-listener -n cicd
```

## Watch PipelineRuns

What: Watches PipelineRuns as they change state.
Why: Lets you follow the triggered build through completion.
How: Stop watching with `Ctrl+C` after the run reaches a terminal state.

```bash
kubectl get pipelineruns -n cicd -w
```

---

# 25. Failure troubleshooting matrix

## Error: ServiceAccount not found

Example:

```text
serviceaccount "github-trigger-sa" not found
```

Check:

What: Verifies the ServiceAccount, Role, RoleBinding, ClusterRole, and ClusterRoleBinding exist.
Why: A missing object can prevent the EventListener from starting.
How: Run after applying the RBAC YAML and check each command returns an object.

```bash
kubectl get sa github-trigger-sa -n cicd
```

Create/apply the ServiceAccount.

---

## Error: Trigger resources forbidden

Example:

```text
github-trigger-sa cannot list triggertemplates
```

Fix the Role and ClusterRole permissions.

Validate:

What: Tests the exact Kubernetes permissions used by `github-trigger-sa`.
Why: A `yes` result proves the RBAC is effective, not just that the YAML exists.
How: Every requested permission should return `yes`.

```bash
kubectl auth can-i list triggertemplates.triggers.tekton.dev \
  --as=system:serviceaccount:cicd:github-trigger-sa \
  -n cicd
```

---

## Error: webhook can only call allowed HTTP servers

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

## Error: wrong NodePort

Example:

```text
Connection refused
```

Check:

What: Shows the Service and the real NodePort allocated to the EventListener.
Why: The generated port is authoritative and prevents using an old port such as 31878.
How: Use the `8080:<nodePort>` mapping for the webhook URL.

```bash
kubectl get svc el-travelportal-github-listener -n cicd
```

The lab's working mapping was:

```text
8080:31877/TCP
```

Do not use an old/incorrect port such as `31878`.

---

## EventListener returns 202 but no PipelineRun

Check:

What: Reads the EventListener logs once.
Why: Useful when Gitea returns `202` but no PipelineRun appears.
How: Look for interceptor, binding, template, or permission errors.

```bash
kubectl logs deployment/el-travelportal-github-listener -n cicd
```

Then inspect:

What: Dumps the TriggerBinding, TriggerTemplate, and EventListener objects together.
Why: These three resources form the trigger chain.
How: Compare names, references, branch filter, params, and template settings.

```bash
kubectl get triggerbinding travelportal-github-binding -n cicd -o yaml
kubectl get triggertemplate travelportal-github-template -n cicd -o yaml
kubectl get eventlistener travelportal-github-listener -n cicd -o yaml
```

Check the CEL filter against the actual Gitea payload.

---

## Gitea webhook Response = 0

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

## Pipeline update-values push fails with fetch first

Use:

What: Fetches the latest remote `main` and resets the local clone to it.
Why: Prevents non-fast-forward failures when another commit arrived meanwhile.
How: Reapply the intended `values.yaml` edit after the reset, then commit and push.

```bash
git fetch origin main
git reset --hard origin/main
```

then reapply the values change and commit.

Do not force push.

---

# 26. Final working architecture

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

# 27. Operational rule

For the normal developer workflow:

What: Creates and pushes a real developer commit.
Why: Exercises the complete Gitea-to-Tekton trigger path.
How: Run from the TravelPortal repository on branch `main`.

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

# 28. Important configuration rules

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

# 29. References

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
