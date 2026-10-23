---
name: dra-gpu-allocation-workflows
description: Explain, design, and troubleshoot NVIDIA GPU allocation through Kubernetes DRA, including ResourceClaims, ResourceSlices, scheduler selection, kubelet Prepare, CDI injection, MIG, and VFIO. Use when asked about GPU claims, MIG allocation, VFIO passthrough, CDI injection, scheduling, or NVIDIA GPU resource attributes.
metadata:
  author: "DRA Driver for NVIDIA GPUs team"
---

# GPU allocation workflows

Reason from the current checkout and, when a cluster is involved, from its observed objects. Keep the scheduler's allocation decision separate from the GPU kubelet plugin's node-local preparation work; most confusing failures become clear once that boundary is identified.

This skill covers the `gpu.nvidia.com` driver. Route IMEX channel and ComputeDomain lifecycle questions through the ComputeDomain implementation and documentation instead.

## Establish the contract in use

Before explaining a manifest or failure, identify:

- The served Kubernetes DRA API version and the manifest's `resource.k8s.io` version.
- The driver's chart/image version and enabled feature gates.
- The requested DeviceClass, request names, selectors, capacity requests, constraints, and opaque NVIDIA config.
- Whether the workload uses a direct `ResourceClaim`, a per-pod claim generated from a `ResourceClaimTemplate`, or one claim shared by multiple pods or containers.
- Whether the node advertises a full GPU, a static MIG device, an abstract dynamic MIG partition, or a VFIO representation.
- The exact phase where progress stops: publication, scheduling/allocation, kubelet Prepare, CDI/runtime injection, workload execution, or Unprepare.

Use the repository's current versioned examples. Do not copy legacy `v1alpha2` manifests from old demo directories into a current cluster. The Kubernetes DRA API version and the NVIDIA opaque config API version are separate contracts; for example, a `resource.k8s.io/v1` claim can contain `resource.nvidia.com/v1beta1` parameters.

## Use the end-to-end model

Trace allocation in this order:

1. **Discover and publish.** Each GPU kubelet plugin discovers node-local hardware and publishes a `gpu.nvidia.com` pool through one or more `ResourceSlice` objects. The slices contain device names, types, attributes, capacity, health taints, and—for partitionable devices—shared counters.
2. **Filter by DeviceClass.** The built-in DeviceClasses select entries from those slices:
   - `gpu.nvidia.com` selects `type == 'gpu'`.
   - `mig.nvidia.com` selects `type == 'mig'`.
   - `vfio.gpu.nvidia.com` selects `type == 'vfio'`.
   All three resource types are published by the same driver, `gpu.nvidia.com`.
3. **Express demand.** A `ResourceClaim` or `ResourceClaimTemplate` names a DeviceClass and can narrow candidates with CEL selectors, capacity requests, constraints, and opaque device configuration.
4. **Allocate and bind.** The Kubernetes scheduler reads ResourceSlices from the API, selects a device compatible with the pod's placement, and records the decision in `ResourceClaim.status.allocation`. The scheduler does not ask the NVIDIA plugin to choose a device. The important handoff fields are the allocation result's driver, pool, device, and request names, plus any allocation node selector.
5. **Prepare on the selected node.** Kubelet calls the registered GPU plugin's Prepare callback. The plugin consumes the already allocated device names and config, performs mode-specific setup, writes a claim-scoped CDI spec, checkpoints the prepared state, and returns fully qualified CDI device IDs.
6. **Inject and run.** Kubelet passes those CDI IDs to the container runtime. The runtime reads the CDI spec and applies device nodes, mounts, hooks, and environment edits to each container that references the claim.
7. **Unprepare and restore.** When kubelet releases the claim, the plugin uses its checkpoint to reverse dynamic MIG, VFIO, MPS, Fabric Manager, and CDI state as applicable. Prepare and Unprepare are designed to be idempotent and recover from partial work, but incomplete cleanup must be diagnosed before manual intervention.

Do not describe `ResourceSlice` publication as a live scheduler-to-plugin query. Publication happens through Kubernetes API objects; Prepare is the later kubelet-to-plugin call.

## Map names across the objects

Keep these names distinct when reviewing YAML:

- `Pod.spec.resourceClaims[].name` creates the pod-local handle and identifies a `ResourceClaim` or `ResourceClaimTemplate` source.
- `container.resources.claims[].name` selects that pod-local handle. If a claim has multiple device requests, `request` narrows which request the container consumes.
- `ResourceClaim.spec.devices.requests[].name` names a device request.
- `ResourceClaim.status.allocation.devices.results[].request` maps that request to the selected driver, pool, and device.
- The plugin returns CDI IDs for the allocated device; those are runtime identifiers, not ResourceSlice device names or GPU UUIDs.

Sharing one claim between two containers gives both containers access to the claim's device. That is different from letting independent claims share capacity on one device, and different again from configuring CUDA time slicing or MPS. State which kind of sharing is intended before recommending configuration.

## Reason about attributes and selectors

Inspect the target cluster's ResourceSlices before writing CEL. Use `site/content/docs/reference/resourceslice-attributes.md` for exact semantics, but treat live published values as decisive.

```bash
kubectl get deviceclass -o yaml
kubectl get resourceslice -o yaml
kubectl get resourceslice -o json
```

NVIDIA attributes are accessed through the qualified namespace, for example:

```text
device.attributes['gpu.nvidia.com'].profile
device.attributes['gpu.nvidia.com'].productName
```

Important distinctions include:

- Full GPU: architecture, product name, UUID, CUDA/driver versions, topology attributes, and memory or engine capacity where published.
- MIG: profile and parent UUID, inherited topology, dedicated memory, and engine capacity.
- VFIO: PCI/vendor/device identifiers, IOMMUFD capability, addressable memory, and optional Fabric Manager partition attributes.
- Standard Kubernetes attributes such as PCI bus, PCIe root, and NUMA locality use the `resource.kubernetes.io` namespace.

Use `device.capacity[...]` for capacity and `device.attributes[...]` for attributes; do not compare a display label such as a MIG profile's `5gb` suffix with the slice's actual usable memory capacity. Use `constraints[].matchAttribute` when multiple requests must share a property such as `gpu.nvidia.com/parentUUID` or a Fabric Manager partition ID.

When a selector matches nothing, compare its exact type and value with the live slice. CEL string, integer, boolean, version, quantity, and list values are not interchangeable.

## Distinguish GPU, MIG, and VFIO preparation

### Full GPU

A full GPU usually needs no hardware reconfiguration. Prepare resolves the allocated device, applies optional sharing or Fabric Manager configuration, generates CDI edits from the NVIDIA container-toolkit libraries, and returns claim-specific CDI IDs.

Optional sharing has separate gates and constraints:

- `ConsumableShares` makes supported GPU or MIG devices multi-allocatable and lets Kubernetes account across independent claims.
- `TimeSlicingSettings` applies CUDA time-slice settings to full GPUs.
- `MPSSupport` starts an MPS control daemon and adds its container edits. The daemon is per claim, or per device and shared by all its claims under consumable shares, where each claim's consumed capacity becomes MPS client limits and a claim may have only one MPS device. It is currently incompatible with dynamic MIG.

Verify the current constraints in `site/content/docs/reference/feature-gates.md` rather than assuming all sharing modes compose.

### Static MIG

The administrator creates MIG instances before plugin startup. The plugin discovers concrete instances and publishes them with profile and parent attributes. Discovery is a startup snapshot: after out-of-band MIG reconfiguration, restart the GPU kubelet plugin so its inventory matches hardware. MIG mode with no instances can advertise neither a full GPU nor usable static MIG devices.

Scheduling chooses an existing MIG device; Prepare injects its parent and MIG capability device nodes through CDI. Static MIG does not require the `DynamicMIG` feature gate.

### Dynamic MIG

With `DynamicMIG`, ResourceSlices advertise possible profile-and-placement devices plus per-GPU shared counters before those MIG instances exist. The scheduler can allocate an abstract partition because counters prevent physically overlapping choices. Prepare creates the GPU instance and compute instance on demand, records the concrete MIG identity in the checkpoint, and generates CDI. Unprepare destroys it when it is no longer used.

Check both the driver gate and the cluster's partitionable-device support. Kubernetes 1.34 and 1.35 require the corresponding Kubernetes gate; current documentation records the exact supported versions and defaults. Dynamic MIG is mutually exclusive with passthrough support and MPS in the current implementation.

Treat the node-local checkpoint as critical recovery state. Do not manually create, delete, or reshape MIG devices on a node managed by dynamic MIG while claims may be prepared.

### VFIO passthrough

VFIO is a different representation of the same physical GPU, not another shareable device. It requires `PassthroughSupport`, IOMMU readiness, and release of host processes that hold the NVIDIA device. Prepare rebinds the selected PCI device to the applicable VFIO driver and emits VFIO CDI edits; Unprepare returns it to the NVIDIA driver. `DeviceMetadata` and the `VfioDeviceConfig` IOMMU settings control API-device exposure needed by consumers such as KubeVirt.

With passthrough enabled, a node can initially advertise GPU and VFIO siblings for one physical device. If both are allocated before either Prepare completes, the scheduler can select conflicting representations; the first preparation wins and removes the sibling representation from subsequent ResourceSlice publication. For reliable mixed environments, serialize such workloads or dedicate and constrain separate node sets.

Do not respond to VFIO Prepare timeouts by immediately restarting or rebinding devices. First find open GPU handles, plugin events, the selected PCI device, and the current kernel driver. Rebinding or stopping node services is disruptive and requires explicit authorization and exact scope.

## Understand CDI as the final handoff

The plugin writes one transient CDI spec per claim using the `k8s.gpu.nvidia.com/claim` vendor/class convention. Each spec contains claim-qualified devices:

- Full GPU entries derive device edits from NVIDIA CDI discovery.
- MIG entries combine the parent GPU edits with the GI and CI capability device nodes.
- VFIO entries are constructed from PCI/IOMMU device information and the claim's `VfioDeviceConfig`.
- MPS or other device configuration can append group-specific container edits.

The plugin returns the qualified CDI names to kubelet; it does not directly modify the application container. A claim can be allocated and prepared successfully while runtime injection still fails if the CDI directory is not shared correctly, the runtime lacks CDI support, the spec is missing, or the container omitted the corresponding claim reference.

## Diagnose at the first broken boundary

Gather evidence without changing the cluster first:

```bash
kubectl get resourceslice -o yaml
kubectl get deviceclass -o yaml
kubectl get resourceclaim -A -o yaml
kubectl get pod -A -o wide
kubectl describe pod -n <namespace> <pod>
kubectl get events -n <namespace> --sort-by=.lastTimestamp
kubectl logs -n dra-driver-nvidia-gpu -l dra-driver-nvidia-gpu-component=kubelet-plugin -c gpus
```

Classify the result:

| Evidence | Likely boundary |
| --- | --- |
| No NVIDIA ResourceSlice or expected device | discovery, plugin registration, hardware mode, feature gate, or publication |
| Device exists but the DeviceClass/selector matches none | class selector, attribute type/value, capacity, taint, or pool completeness |
| Claim has no `status.allocation` and pod is Pending | scheduler allocation, node compatibility, request constraint, or capacity |
| Allocation exists but pod reports `FailedPrepareDynamicResources` | kubelet-to-plugin Prepare, device/config mismatch, hardware transition, checkpoint, or host service |
| Prepare returns CDI IDs but container creation fails | CDI spec visibility, runtime CDI support, driver root, device nodes, or hook execution |
| Container runs but lacks the intended device | pod/container claim mapping, returned CDI selection, or workload-level visibility check |
| Release is stuck or resources stay hidden | Unprepare, checkpoint cleanup, VFIO restore, dynamic MIG deletion, MPS teardown, or slice republish |

Inspect the claim's allocation result before reading plugin logs: it proves what Kubernetes chose. In plugin logs, correlate namespace, claim name, claim UID, request, pool, and device. A ResourceSlice device name, claim UID, CDI ID, PCI bus ID, and GPU/MIG UUID identify different layers; label each explicitly in the explanation.

Do not use `kubectl apply/delete`, restart plugins, edit feature gates, reconfigure MIG, rebind PCI devices, or stop node services during a diagnosis-only request. If the user asks for a fix, explain the expected state transition, target the smallest affected object or node, and define a stopping condition before mutating hardware or cluster state.

## Follow source ownership

Use these files to verify detailed claims and locate changes:

- `site/content/docs/concepts/gpu-allocation.md`: user-facing resource types and request flow.
- `site/content/docs/reference/resourceslice-attributes.md`: published attribute and capacity contract.
- `site/content/docs/reference/feature-gates.md`: current gates, Kubernetes dependencies, and incompatible combinations.
- `deployments/helm/dra-driver-nvidia-gpu/templates/deviceclass-*.yaml`: built-in DeviceClass selectors.
- `cmd/gpu-kubelet-plugin/driver.go`: plugin registration, ResourceSlice generation/publication, and Prepare/Unprepare entry points.
- `cmd/gpu-kubelet-plugin/allocatable.go`, `deviceinfo.go`, and `nvlib.go`: node inventory and published device representations.
- `cmd/gpu-kubelet-plugin/device_state.go`: claim preparation state machine, allocation/config decoding, mode-specific setup, rollback, and checkpoint transitions.
- `cmd/gpu-kubelet-plugin/mig.go` and `partitions.go`: static/dynamic MIG identities and partitionable-device publication.
- `cmd/gpu-kubelet-plugin/vfio-device.go`, `vfio-cdi.go`, and the VFIO manager files: PCI rebinding and IOMMU/CDI behavior.
- `cmd/gpu-kubelet-plugin/cdi.go`: transient claim specs and returned CDI identifiers.
- `cmd/gpu-kubelet-plugin/checkpoint*.go`, `prepared.go`, and `cleanup.go`: persisted prepared state and recovery.
- `api/nvidia.com/resource/v1beta1/`: opaque `GpuConfig`, `MigDeviceConfig`, and `VfioDeviceConfig` contracts, normalization, and validation.
- `demo/specs/quickstart/`, `site/content/docs/guides/gpu-allocation/`, and `test/e2e/gpu_allocation_test.go`: versioned examples, supported workflows, and observable allocation assertions.

Use adjacent unit tests to confirm edge cases. For a change to the API or feature-gate contract, also load `dra-api-crd-feature-gate-change`; for a live install or sample execution, load `dra-helm-demo-sample-workloads`.

## Shape the response

Lead with the selected or failing boundary, then show the evidence connecting the claim request to the published device, allocation result, prepared device, and CDI identifier. For manifest reviews, separate desired state from scheduler-populated status. For debugging, give the next discriminating observation before remediation. Call out feature-gated behavior, hardware mutations, generated code, and any place where documentation differs from the current implementation.
