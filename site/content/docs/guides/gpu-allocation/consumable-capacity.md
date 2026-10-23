---
title: Share GPUs with consumable capacity
linkTitle: Consumable capacity
weight: 42
description: Share full GPUs and MIG devices across independent ResourceClaims with consumable capacity.
---

Kubernetes DRA consumable capacity lets multiple independent `ResourceClaim` objects allocate the same physical GPU or MIG device.
The NVIDIA driver exposes this capability through its `ConsumableShares` feature gate and `consumableShares` Helm value.
It marks supported devices as multi-allocatable and publishes a capacity policy; the Kubernetes scheduler then tracks how much capacity each claim consumes.

Use consumable capacity when separate pods need independent claims but can safely co-locate on one device.
This differs from time-slicing and MPS, where multiple containers reference an allocation with a driver-specific sharing configuration.
To also limit what each claim uses on the GPU, combine consumable capacity with MPS, as described in [Apply capacity limits with MPS](#apply-capacity-limits-with-mps).

## Feature status

`ConsumableShares` is the NVIDIA driver's Alpha feature gate and is disabled by default.
It must be enabled together with a non-disabled `consumableShares` mode.
The corresponding upstream Kubernetes feature is DRA consumable capacity, controlled by the `DRAConsumableCapacity` feature gate.

| Feature gate | Stage | Default |
|---|---|---|
| `ConsumableShares` | Alpha | `false` |

Refer to the [feature gates reference](../../reference/feature-gates.md) for all available gates.

## Prerequisites

- Install the DRA Driver for NVIDIA GPUs.
  Refer to [Installation](../../install.md).
- Use Kubernetes v1.34 or later.
  On Kubernetes v1.34 and v1.35, enable the upstream `DRAConsumableCapacity` feature gate on the kube-apiserver, kube-controller-manager, kube-scheduler, and kubelet.
  Kubernetes v1.36 and later enables that gate by default.
  Refer to [Kubernetes consumable capacity](https://kubernetes.io/docs/concepts/scheduling-eviction/dynamic-resource-allocation/#consumable-capacity).
- Use the `gpu.nvidia.com` or `mig.nvidia.com` DeviceClass.
  The driver's consumable-capacity implementation does not support VFIO passthrough devices.

## Enable consumable capacity

Enable the driver's consumable-capacity implementation and choose one driver-specific accounting mode for all GPU kubelet plugins in the Helm release.
This example selects memory-based accounting:

```bash
helm upgrade dra-driver-nvidia-gpu oci://registry.k8s.io/dra-driver-nvidia/charts/dra-driver-nvidia-gpu \
  --namespace dra-driver-nvidia-gpu \
  --set featureGates.ConsumableShares=true \
  --set consumableShares=memory \
  --set gpuResourcesEnabledOverride=true
```

The Helm upgrade rolls the GPU kubelet plugin pods so they republish their `ResourceSlice` objects with `allowMultipleAllocations: true` and the selected capacity request policy.

To disable the feature, set `consumableShares=disabled` or clear the value.
You can then disable the `ConsumableShares` feature gate.

## Choose a capacity accounting mode

| `consumableShares` value | Behavior when a claim omits a capacity request |
|---|---|
| `memory` | Consumes the device's full advertised memory capacity unless a claim requests a smaller amount in 1 MiB increments. |
| `unlimited` | Consumes zero memory capacity by default, so the scheduler does not limit the number of claims that omit a memory request, although a claim can still request an explicit amount of memory. |
| Positive integer, such as `4` | Publishes that many `shares`, with each claim consuming one share by default unless it requests more, while memory consumption defaults to zero. |
| `disabled` or empty | Does not publish multi-allocation or consumable-capacity policies and is the default. |

The mode is a cluster-administrator setting applied to supported devices on every node managed by the Helm release.
Workload authors express their needs in the `capacity.requests` map of a `ResourceClaim` or `ResourceClaimTemplate`.

### Memory mode

With `consumableShares=memory`, request the amount of GPU memory that the scheduler should reserve for each claim:

```yaml
apiVersion: resource.k8s.io/v1
kind: ResourceClaimTemplate
metadata:
  name: gpu-4gi
spec:
  spec:
    devices:
      requests:
      - name: gpu
        exactly:
          deviceClassName: gpu.nvidia.com
          capacity:
            requests:
              memory: 4Gi
```

Each pod that references this template gets its own claim.
Kubernetes can allocate multiple claims to one GPU while their combined requested memory fits within the device's advertised memory capacity.
If `capacity.requests.memory` is omitted in memory mode, the claim consumes the full memory capacity and no other memory-consuming claim can be allocated to that device.

### Unlimited mode

With `consumableShares=unlimited`, omit `capacity` from the device request:

```yaml
devices:
  requests:
  - name: gpu
    exactly:
      deviceClassName: gpu.nvidia.com
```

The claim consumes zero capacity by default.
The scheduler can therefore place an unbounded number of these claims on the same device, subject to its other scheduling constraints.

### Fixed share count

Set `consumableShares` to a positive integer to publish a fixed number of shares.
For example, `consumableShares=4` lets four claims that use the default of one share co-allocate on a device.
To consume more than the default, add a `shares` request:

```yaml
capacity:
  requests:
    shares: 2
```

## Apply capacity limits with MPS

The capacity that a claim consumes is otherwise only scheduler accounting.
When the `MPSSupport` feature gate is also enabled, a claim that selects the MPS sharing strategy gets its consumed capacity applied as MPS client limits:

| Consumed capacity | MPS client limit |
|---|---|
| `memory` | `CUDA_MPS_PINNED_DEVICE_MEM_LIMIT` for the device, in MiB. |
| `shares` | `CUDA_MPS_ACTIVE_THREAD_PERCENTAGE`, computed as consumed shares × 100 / `consumableShares`, rounded down, and at least 1. |

A claim that consumes none of a capacity gets no limit for it, so the settings in its `mpsConfig` apply.
For example, with `consumableShares=4`, each pod that uses this template can use 25% of the GPU's threads and 4096 MiB of pinned device memory:

```yaml
apiVersion: resource.k8s.io/v1
kind: ResourceClaimTemplate
metadata:
  name: gpu-mps-quarter
spec:
  spec:
    devices:
      requests:
      - name: gpu
        exactly:
          deviceClassName: gpu.nvidia.com
          capacity:
            requests:
              shares: 1
              memory: 4Gi
      config:
      - requests: ["gpu"]
        opaque:
          driver: gpu.nvidia.com
          parameters:
            apiVersion: resource.nvidia.com/v1beta1
            kind: GpuConfig
            sharing:
              strategy: MPS
```

The driver runs one MPS control daemon per shared GPU or MIG device, a Deployment named `mps-control-daemon-shared-<id>`.
All claims on that device use it, and the driver removes it when the last of them is released.

Keep these constraints in mind:

- **One MPS device per claim.**
  A CUDA process can connect to only one MPS control daemon, so the driver rejects a claim with more than one MPS device in this mode.
  Use one such claim per container.
- **One `mpsConfig` per device.**
  All claims on a device configure the same shared daemon, so their configurations must match.
  The scheduler does not consider `mpsConfig`; a claim with a different configuration that is allocated a device in use fails to prepare.
  Put the configuration in a dedicated `DeviceClass` so that its claims share it.
- **Limits apply per process and are cooperative.**
  MPS applies the limits to each CUDA process, so several processes in a claim's containers can together exceed them, and a process can unset the variables.
  The `defaultActiveThreadPercentage` and `defaultPinnedDeviceMemoryLimit` settings of the shared daemon are the hard ceiling for all its clients, and they apply when they are lower than a claim's limits.

## Verify shared allocations

Inspect the published device policy:

```bash
kubectl get resourceslices -o yaml
```

For supported devices, verify that `allowMultipleAllocations` is `true` and that the `memory` or `shares` capacity contains the expected `requestPolicy`.

After creating workloads, inspect their claims:

```bash
kubectl get resourceclaims -A -o yaml
```

For a shared allocation, the allocation result records a `shareID` and its `consumedCapacity`.
Example manifests for all three modes are available under [`demo/specs/consumable-shares/`](https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu/tree/{{< param driver_release_tag >}}/demo/specs/consumable-shares).

## Limitations and considerations

- **Capacity is scheduling accounting, not runtime isolation.**
  A memory value reserves scheduler-visible capacity but does not limit a process's CUDA memory use, unless the claim also uses MPS as described in [Apply capacity limits with MPS](#apply-capacity-limits-with-mps).
  Workloads sharing a device can affect each other's memory use and performance.
- **MPS claims are limited to one device.**
  The driver rejects an MPS-configured claim with more than one MPS device, and claims on one device must use the same `mpsConfig`.
- **VFIO passthrough is not supported.**
  The driver implements consumable capacity only for full GPUs and static or dynamic MIG devices.
- **Claims must use matching device configurations.**
  If a device is already prepared for another shared claim, a new claim with a conflicting `GpuConfig` or `MigDeviceConfig` fails to prepare.
- **Unlimited means unbounded scheduler placement.**
  Because a claim without a memory request consumes zero capacity in `unlimited` mode, use this mode only when the workloads can tolerate unrestricted contention.
