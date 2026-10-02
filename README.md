# sandboxed-containers

Test log for installing OpenShift sandboxed containers (Kata
Containers) on OpenShift and OKD lab clusters.

| Platform  | Log                            | Manifests     |
|-----------|--------------------------------|---------------|
| OpenShift | [openshift.md](openshift.md)   | `openshift/`  |
| OKD       | [okd.md](okd.md)               | `okd/`        |

Each log is written so the install can be reproduced on a fresh
cluster by following it top to bottom. The goal of each test is to
start a pod with the `kata` runtime class and run podman inside it to
start a nested container.

[prompt.md](prompt.md) holds the prompt used to drive the test runs.
