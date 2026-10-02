# Tips for the OKD run

Notes from the OpenShift run on 2026-09-30, for the agent repeating the
task on OKD. Read [openshift.md](openshift.md) first; the manifests in
`openshift/` are the starting point. Put the OKD manifests in `okd/`,
write the log to `okd.md`, and add the OKD row to the table in
`README.md`.

Items marked unverified are expectations, not observations.

## Check what cluster you are on

- Don't go by the context or host name. Today's context was
  `addon-trivy/api-okd4-example-com:6443/system:admin` and the API
  host was `api.okd4.example.com`, but the cluster was OpenShift 4.20.24
  on RHCOS. Check with `oc get clusterversion` and the `OS-IMAGE`
  column of `oc get nodes -o wide`.
- If it's the same machines reinstalled, the node names will likely be
  the same (`worker1/2.okd4.example.com`). If it's the same cluster
  without a reinstall, kata from today is still installed: check
  `oc get kataconfig` and remove it before starting.
- Workers need `/dev/kvm`. Today both workers were bare metal and had
  it.

## Differences expected on OKD (unverified)

- Catalog: OKD normally has no `redhat-operators` CatalogSource, since
  it needs a registry.redhat.io pull secret. Run
  `oc get packagemanifests -n openshift-marketplace | grep -i sandbox`
  first. Possible sources, in order of preference:
  1. `community-operators` or `operatorhubio-catalog`, if either
     carries `sandboxed-containers-operator`. Check which channels and
     versions are available.
  2. Add the `redhat-operators` index as a CatalogSource. This needs a
     Red Hat pull secret, so ask the user before touching the global
     pull secret.
  3. The upstream operator from
     github.com/openshift/sandboxed-containers-operator.
- RHCOS extension: the operator enables kata with a MachineConfig
  (`50-enable-sandboxed-containers-extension`) that sets
  `extensions: ["sandboxed-containers"]`. On OKD the nodes run
  SCOS/FCOS, and that extension may not exist. If the `kata-oc` pool
  goes Degraded, read the reason with
  `oc describe mcp kata-oc` and the machine-config-daemon logs on the
  node. Fallbacks:
  - upstream kata-deploy (github.com/kata-containers/kata-containers,
    `tools/packaging/kata-deploy`), which installs kata into
    `/opt/kata` with a DaemonSet and configures CRI-O
  - rpm-ostree layering or on-cluster image layering with the
    `kata-containers` package
- If kata-deploy is used, the RuntimeClass name and handler may not be
  `kata`. Check `oc get runtimeclass` and adjust `runtimeClassName` in
  the pod manifest.
- A MachineConfig change reboots the nodes, so a broken extension can
  leave a worker cordoned or NotReady. If a node doesn't come back,
  stop and tell the user to reinstall it.

## Things that worked today and should carry over

- Operator install: Namespace, OperatorGroup and Subscription
  (`openshift/01-operator.yaml`). The CSV reached Succeeded in about 2
  minutes. Other operators' copied CSVs also appear in
  `oc get csv -n openshift-sandboxed-containers-operator`; filter with
  `grep sandboxed`.
- KataConfig: `spec.checkNodeEligibility` is required in 1.13. Set it
  to `false` unless NFD is installed. Leaving out
  `kataConfigPoolSelector` puts kata on all workers. The rollout took
  about 11 minutes for two workers, one reboot each.
- Done when the KataConfig `InProgress` condition is `False`,
  `readyNodeCount` equals `nodeCount`, and `oc get runtimeclass`
  lists `kata`.
- Podman inside kata needs all three of these, all in
  `openshift/03-podman-in-kata.yaml`:
  - `privileged: true` through a RoleBinding to
    `system:openshift:scc:privileged`
  - an `emptyDir` with `medium: Memory` at `/var/lib/containers`
  - a replacement `/etc/containers/storage.conf` (overlay, graphroot
    on the tmpfs, no `mount_program`, no `imagestore`)
- Failures seen without those fixes, in order:
  1. `fuse: device /dev/fuse not found`, because the image forces
     fuse-overlayfs and kata doesn't pass host devices through
  2. `invalid argument` on the overlay mount, because the image's
     `imagestore` is on the virtiofs rootfs
  3. `--storage-driver=vfs` fails with a graph driver mismatch unless
     storage is reset first; not needed with the fix above
- Proving the pod is in a VM:
  - guest `nproc` is 1 while the host has 12
  - guest `/proc/cmdline` contains `console=hvc0` and `agent.log=`
  - on the node, `crictl pods --name podman-in-kata -q` gives the
    sandbox id, and `pgrep -af "qemu-kvm -name sandbox-<id>"` finds
    the VM
  - `uname -r` alone proves nothing on RHCOS, since guest and host
    kernels are the same build. With kata-deploy on OKD the versions
    will likely differ, which would make it useful evidence.

## Harness tips

- Every `oc` call needs `allowed_domains: ["api.okd4.example.com:6443"]`,
  or the host from tomorrow's context. Without it the sandbox proxy
  answers `Unable to connect to the server: Forbidden`.
- A foreground `sleep` is blocked. To wait for the KataConfig, use a
  background Bash `until` loop; to follow the MCP and node status, use
  Monitor, with the loop exiting on `updatedMachineCount` = node count
  and also printing degraded counts.
- In zsh, `E="oc exec ... --"; $E cmd` fails with "command not found".
  Use a function instead: `e(){ oc exec -n kata-test podman-in-kata -- "$@"; }`.
- `oc debug node/... -q -- chroot /host sh -c '...'` works for
  node-side checks. Send stderr to `/dev/null` to hide the debug pod
  noise.
- Writing `.claude/settings.json` is blocked for the agent. The user
  has to edit it.
- Per the user's global instructions: don't commit unless asked, wrap
  Markdown at 72 columns, and don't use bold for emphasis.

## Still open from the OpenShift run

- The cleanup steps in `openshift.md` were never run. Removing the
  KataConfig reboots the workers again.
