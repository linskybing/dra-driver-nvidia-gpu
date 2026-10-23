# shellcheck disable=SC2148
# shellcheck disable=SC2329

# Tests for ConsumableShares GPU sharing mode.
# Requires feature gate: ConsumableShares=true.

setup_file() {
  load 'helpers.sh'
  _common_setup
  local _iargs=("--set" "logVerbosity=6"
    "--set" "featureGates.MPSSupport=true"
    "--set" "featureGates.ConsumableShares=true"
    "--set" "consumableShares=4")
  if [ "${DISABLE_COMPUTE_DOMAINS:-}" = "true" ]; then
    _iargs+=("--set" "resources.computeDomains.enabled=false")
  fi
  iupgrade_wait "${TEST_CHART_REPO}" "${TEST_CHART_VERSION}" _iargs

  # The MPS tests pin all their claims to one GPU so that they share it.
  TEST_CS_GPU_UUID=$(kubectl get resourceslices -o json | jq -r '[.items[]
    | select(.spec.driver=="gpu.nvidia.com") | .spec.devices[]?
    | select(.attributes.type.string=="gpu") | .attributes.uuid.string][0]')
  export TEST_CS_GPU_UUID
  kubectl apply -f tests/bats/specs/gpu-consumable-shares-mps-probe-src.yaml
}

teardown_file() {
  kubectl delete -f tests/bats/specs/gpu-consumable-shares-mps-probe-src.yaml --ignore-not-found
}

setup() {
  load 'helpers.sh'
  _common_setup
  log_objects
}

teardown() {
  # Leftovers from a failed MPS test would hold the shared GPU for the next one.
  kubectl delete pods,resourceclaimtemplates -l env=batssuite,test=cs-mps --ignore-not-found --timeout=120s || true
}

bats::on_failure() {
  echo -e "\n\nFAILURE HOOK START"
  log_objects
  show_kubelet_plugin_error_logs
  show_gpu_plugin_log_tails
  echo -e "FAILURE HOOK END\n\n"
}

# bats test_tags=fastfeedback,gpu-sharing,consumable-shares
@test "GPUs: ConsumableShares — memory mode with 2 independent pods" {
  local _specpath="tests/bats/specs/gpu-consumable-shares-memory.yaml"

  kubectl apply -f "${_specpath}"
  kubectl wait --for=condition=READY pods "pod-share-memory-0" --timeout=45s
  kubectl wait --for=condition=READY pods "pod-share-memory-1" --timeout=45s

  run kubectl logs "pod-share-memory-0" -c ctr
  assert_output --partial "UUID: GPU-"
  local uid0="${output}"

  run kubectl logs "pod-share-memory-1" -c ctr
  assert_output --partial "UUID: GPU-"
  local uid1="${output}"

  assert_equal "$uid0" "$uid1"

  kubectl delete -f "${_specpath}"
  kubectl wait --for=delete pods "pod-share-memory-0" --timeout=30s
  kubectl wait --for=delete pods "pod-share-memory-1" --timeout=30s
}

# bats test_tags=fastfeedback,gpu-sharing,consumable-shares
@test "GPUs: ConsumableShares — integer shares mode with 2 independent pods" {
  local _specpath="tests/bats/specs/gpu-consumable-shares-integer.yaml"

  kubectl apply -f "${_specpath}"
  kubectl wait --for=condition=READY pods "pod-share-integer-0" --timeout=45s
  kubectl wait --for=condition=READY pods "pod-share-integer-1" --timeout=45s

  run kubectl logs "pod-share-integer-0" -c ctr
  assert_output --partial "UUID: GPU-"
  local uid0="${output}"

  run kubectl logs "pod-share-integer-1" -c ctr
  assert_output --partial "UUID: GPU-"
  local uid1="${output}"

  assert_equal "$uid0" "$uid1"

  kubectl delete -f "${_specpath}"
  kubectl wait --for=delete pods "pod-share-integer-0" --timeout=30s
  kubectl wait --for=delete pods "pod-share-integer-1" --timeout=30s
}

# bats test_tags=fastfeedback,gpu-sharing,consumable-shares
@test "GPUs: ConsumableShares — 2 MPS pods share one MPS control daemon" {
  if [ "${MOCK_NVML:-}" = "true" ]; then skip "requires real MPS daemon"; fi
  local _specpath="tests/bats/specs/gpu-consumable-shares-mps.yaml"

  kubectl apply -f "${_specpath}"
  kubectl wait --for=condition=READY pods "pod-share-mps-0" --timeout=60s
  kubectl wait --for=condition=READY pods "pod-share-mps-1" --timeout=60s

  # Each claim's consumed capacity becomes its MPS client limits.
  run kubectl logs "pod-share-mps-0" -c ctr
  assert_output --partial "UUID: GPU-"
  assert_output --partial "CUDA_MPS_ACTIVE_THREAD_PERCENTAGE=25"
  assert_output --regexp "CUDA_MPS_PINNED_DEVICE_MEM_LIMIT=GPU-[^=]+=1024M"
  local uid0
  uid0=$(grep -o "UUID: GPU-[^)]*" <<< "${output}")

  run kubectl logs "pod-share-mps-1" -c ctr
  assert_output --partial "UUID: GPU-"
  assert_output --partial "CUDA_MPS_ACTIVE_THREAD_PERCENTAGE=75"
  assert_output --regexp "CUDA_MPS_PINNED_DEVICE_MEM_LIMIT=GPU-[^=]+=2048M"
  local uid1
  uid1=$(grep -o "UUID: GPU-[^)]*" <<< "${output}")

  assert_equal "$uid0" "$uid1"

  # Both claims are served by one daemon for the shared GPU.
  local _ns _name
  read -r _ns _name < <(kubectl get deployments -A --no-headers | awk '/mps-control-daemon-shared-/ {print $1, $2}')
  [ -n "${_name}" ]
  assert_equal "$(kubectl get deployments -A --no-headers | grep -c "mps-control-daemon-shared-")" "1"

  # The daemon outlives a claim while another claim still uses the GPU.
  kubectl delete pod "pod-share-mps-0"
  kubectl wait --for=delete pods "pod-share-mps-0" --timeout=30s
  kubectl get deployment -n "${_ns}" "${_name}"

  # It is stopped with the last claim.
  kubectl delete -f "${_specpath}" --ignore-not-found
  kubectl wait --for=delete pods "pod-share-mps-1" --timeout=30s
  kubectl wait --for=delete -n "${_ns}" "deployment/${_name}" --timeout=60s
}

: "${TEST_CS_MPS_STRESS_ITERATIONS:=5}"
: "${TEST_CS_MPS_CHURN_ITERATIONS:=10}"
: "${TEST_CS_TORCH_IMAGE:=pytorch/pytorch:2.5.1-cuda12.4-cudnn9-runtime}"

# Render gpu-consumable-shares-mps-pod.yaml and print the file path.
# Args: name shares memory mode [program-args]; MPS_POD_IMAGE overrides the image.
_mps_pod() {
  local out="${BATS_TEST_TMPDIR}/$1.yaml"
  sed -e "s/__NAME__/$1/g" -e "s/__GPU_UUID__/${TEST_CS_GPU_UUID}/g" \
    -e "s|__IMAGE__|${MPS_POD_IMAGE:-nvidia/cuda:12.5.0-devel-ubuntu22.04}|g" \
    -e "s/__SHARES__/$2/g" -e "s/__MEMORY__/$3/g" -e "s/__MODE__/$4/g" \
    -e "s/__ARGS__/${5:-}/g" \
    tests/bats/specs/gpu-consumable-shares-mps-pod.yaml > "${out}"
  echo "${out}"
}

_start_mps_sleeper() {
  kubectl apply -f "$(_mps_pod "$1" 1 1Gi sleep)"
}

# Args: name shares memory "<start-at-epoch> <seconds> <alloc-ok-MiB> <alloc-over-MiB>"
_start_matmul_pod() {
  kubectl apply -f "$(MPS_POD_IMAGE="${TEST_CS_TORCH_IMAGE}" _mps_pod "$1" "$2" "$3" matmul "$4")"
}

_wait_succeeded() {
  local p
  for p in "$@"; do
    kubectl wait --for=jsonpath='{.status.phase}'=Succeeded "pod/${p}" --timeout=600s
  done
}

_tflops() {
  kubectl logs "$1" -c ctr | grep -oP 'TFLOPS=\K[0-9.]+'
}

# Args: awk expression over numbers, e.g. "1.5 / 3 < 0.6"
_float_ok() {
  awk "BEGIN { exit !($1) }"
}

_delete_mps_pod() {
  kubectl delete pod "$1" --timeout=90s
  kubectl delete resourceclaimtemplate "$1"
}

_mps_daemon_uids() {
  kubectl get deployments -A -o json | jq -r '.items[].metadata
    | select(.name | startswith("mps-control-daemon-shared-")) | .uid'
}

_mps_daemon_count_is() {
  [ "$(_mps_daemon_uids | grep -c . || true)" -eq "$1" ]
}

_no_resource_claims() {
  [ "$(kubectl get resourceclaims --no-headers 2>/dev/null | wc -l)" -eq 0 ]
}

# Args: timeout-seconds command...
_wait_until() {
  local timeout=$1 start=$SECONDS
  shift
  until "$@"; do
    if (( SECONDS - start > timeout )); then
      echo "timeout (${timeout} s) waiting for: $*"
      return 1
    fi
    sleep 2
  done
}

# Everything an MPS claim set up on the node is gone once its last claim is.
_assert_no_mps_leak() {
  _wait_until 120 _no_resource_claims
  _wait_until 120 _mps_daemon_count_is 0

  # Default kubeletPluginsDirectoryPath.
  run kubectl exec -n dra-driver-nvidia-gpu "$(get_one_kubelet_plugin_pod_name)" -c gpus -- \
    sh -c 'ls -A /var/lib/kubelet/plugins/gpu.nvidia.com/mps 2>/dev/null || true'
  assert_output ""

  # MPS teardown must reset the GPU's compute mode.
  local _spec="${BATS_TEST_TMPDIR}/nomps.yaml"
  sed "s/__GPU_UUID__/${TEST_CS_GPU_UUID}/g" tests/bats/specs/gpu-consumable-shares-nomps-pod.yaml > "${_spec}"
  kubectl apply -f "${_spec}"
  kubectl wait --for=condition=READY pods pod-cs-nomps --timeout=60s
  run kubectl logs pod-cs-nomps -c ctr
  assert_output --partial "Default"
  kubectl delete -f "${_spec}" --timeout=90s
}

_sm_count() {
  kubectl logs "$1" -c ctr | grep -oP 'SM_COUNT=\K[0-9]+'
}

# bats test_tags=gpu-sharing,consumable-shares
@test "GPUs: ConsumableShares — MPS client limits are enforced on the GPU" {
  if [ "${MOCK_NVML:-}" = "true" ]; then skip "requires real MPS daemon"; fi

  # shares 1/4 with 2Gi, and shares 3/4 with 6Gi (needs a GPU with >= 8Gi).
  kubectl apply -f "$(_mps_pod cs-mps-probe-1 1 2Gi probe "1024 4096")"
  kubectl apply -f "$(_mps_pod cs-mps-probe-3 3 6Gi probe "4096")"
  kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/cs-mps-probe-1 --timeout=300s
  kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/cs-mps-probe-3 --timeout=300s

  run kubectl logs cs-mps-probe-1 -c ctr
  assert_output --partial "ALLOC_1024MiB=OK"
  assert_output --partial "ALLOC_4096MiB=FAIL"

  # The limits are per claim: the same size fits into the larger claim.
  run kubectl logs cs-mps-probe-3 -c ctr
  assert_output --partial "ALLOC_4096MiB=OK"

  local sm1 sm3
  sm1=$(_sm_count cs-mps-probe-1)
  sm3=$(_sm_count cs-mps-probe-3)
  echo "SM count: shares 1 -> ${sm1}, shares 3 -> ${sm3}"
  [ "${sm1}" -lt "${sm3}" ]

  _delete_mps_pod cs-mps-probe-1
  _delete_mps_pod cs-mps-probe-3
  _assert_no_mps_leak
}

# bats test_tags=gpu-sharing,consumable-shares
@test "GPUs: ConsumableShares — MPS limits hold for user-namespace pods with multiUser" {
  if [ "${MOCK_NVML:-}" = "true" ]; then skip "requires real MPS daemon"; fi
  # Nodes that run in containers (kind) cannot start user-namespace pods.
  if [ "${TEST_SKIP_USERNS:-}" = "true" ]; then skip "user-namespace pods unsupported"; fi
  local _spec="${BATS_TEST_TMPDIR}/userns.yaml"
  sed "s/__GPU_UUID__/${TEST_CS_GPU_UUID}/g" tests/bats/specs/gpu-consumable-shares-mps-userns.yaml > "${_spec}"

  # hostUsers: false maps the pods' root to an unprivileged host UID.
  kubectl apply -f "${_spec}"
  _wait_succeeded cs-mps-userns-1 cs-mps-userns-3

  run kubectl logs cs-mps-userns-1 -c ctr
  assert_output --partial "ALLOC_1024MiB=OK"
  assert_output --partial "ALLOC_3072MiB=FAIL"
  run kubectl logs cs-mps-userns-3 -c ctr
  assert_output --partial "ALLOC_3072MiB=OK"

  local sm1 sm3
  sm1=$(_sm_count cs-mps-userns-1)
  sm3=$(_sm_count cs-mps-userns-3)
  echo "userns SM count: shares 1 -> ${sm1}, shares 3 -> ${sm3}"
  [ "${sm1}" -lt "${sm3}" ]

  kubectl delete -f "${_spec}" --timeout=120s
  _assert_no_mps_leak
}

# bats test_tags=gpu-sharing,consumable-shares
@test "GPUs: ConsumableShares — non-MPS claim waits until the GPU's MPS claims are gone" {
  if [ "${MOCK_NVML:-}" = "true" ]; then skip "requires real MPS daemon"; fi
  local _spec="${BATS_TEST_TMPDIR}/nomps.yaml"
  sed "s/__GPU_UUID__/${TEST_CS_GPU_UUID}/g" tests/bats/specs/gpu-consumable-shares-nomps-pod.yaml > "${_spec}"

  _start_mps_sleeper cs-mps-holder
  kubectl wait --for=condition=READY pods cs-mps-holder --timeout=300s

  # The scheduler places it on the same GPU; the kubelet plugin refuses it.
  kubectl apply -f "${_spec}"
  wait_for_pod_event pod/pod-cs-nomps "conflicting configuration" 120

  _delete_mps_pod cs-mps-holder
  kubectl wait --for=condition=READY pods pod-cs-nomps --timeout=180s
  run kubectl logs pod-cs-nomps -c ctr
  assert_output --partial "Default"

  kubectl delete -f "${_spec}" --timeout=90s
  _assert_no_mps_leak
}

# bats test_tags=gpu-sharing,consumable-shares
@test "GPUs: ConsumableShares — claim with two MPS requests is refused" {
  if [ "${MOCK_NVML:-}" = "true" ]; then skip "requires real MPS daemon"; fi
  local _spec="tests/bats/specs/gpu-consumable-shares-mps-two-requests.yaml"

  # On a single-GPU node both requests land on the same GPU.
  kubectl apply -f "${_spec}"
  wait_for_pod_event pod/pod-cs-mps-two-requests "supports exactly one per claim" 120
  _mps_daemon_count_is 0

  kubectl delete -f "${_spec}" --timeout=90s
  _assert_no_mps_leak
}

# bats test_tags=gpu-sharing,consumable-shares
@test "GPUs: ConsumableShares — shared MPS daemon survives a kubelet plugin restart" {
  if [ "${MOCK_NVML:-}" = "true" ]; then skip "requires real MPS daemon"; fi

  _start_mps_sleeper cs-mps-a
  _start_mps_sleeper cs-mps-b
  kubectl wait --for=condition=READY pods cs-mps-a cs-mps-b --timeout=300s
  local uid
  uid=$(_mps_daemon_uids)
  [ -n "${uid}" ]
  _mps_daemon_count_is 1

  local plugin
  plugin=$(get_one_kubelet_plugin_pod_name)
  kubectl delete pod -n dra-driver-nvidia-gpu "${plugin}"
  kubectl wait --for=delete pod -n dra-driver-nvidia-gpu "${plugin}" --timeout=90s
  kubectl wait --for=condition=READY pods -n dra-driver-nvidia-gpu \
    -l dra-driver-nvidia-gpu-component=kubelet-plugin --timeout=180s

  # Same boot: the checkpoint is kept, so the daemon must not be recreated.
  assert_equal "$(_mps_daemon_uids)" "${uid}"
  kubectl wait --for=condition=READY pods cs-mps-a cs-mps-b --timeout=10s

  _start_mps_sleeper cs-mps-c
  kubectl wait --for=condition=READY pods cs-mps-c --timeout=180s
  assert_equal "$(_mps_daemon_uids)" "${uid}"

  _delete_mps_pod cs-mps-a
  _delete_mps_pod cs-mps-b
  _delete_mps_pod cs-mps-c
  _assert_no_mps_leak
}

# bats test_tags=consumable-shares,stress
@test "GPUs: ConsumableShares — MPS fill and drain, ${TEST_CS_MPS_STRESS_ITERATIONS} repetitions" {
  if [ "${MOCK_NVML:-}" = "true" ]; then skip "requires real MPS daemon"; fi

  for loop in $(seq 1 "${TEST_CS_MPS_STRESS_ITERATIONS}"); do
    echo "=== Loop ${loop}/${TEST_CS_MPS_STRESS_ITERATIONS} ==="
    for i in 1 2 3 4; do _start_mps_sleeper "cs-mps-fill-${i}"; done
    kubectl wait --for=condition=READY pods cs-mps-fill-{1,2,3,4} --timeout=300s
    _mps_daemon_count_is 1

    # All 4 shares are consumed, so a 5th claim cannot be scheduled.
    _start_mps_sleeper cs-mps-fill-5
    sleep 15
    assert_equal "$(kubectl get pod cs-mps-fill-5 -o jsonpath='{.status.phase}')" "Pending"
    assert_equal "$(kubectl get pod cs-mps-fill-5 -o jsonpath='{.spec.nodeName}')" ""

    kubectl delete pods,resourceclaimtemplates -l env=batssuite,test=cs-mps --timeout=120s
    _assert_no_mps_leak
  done
}

# bats test_tags=consumable-shares,stress
@test "GPUs: ConsumableShares — MPS claim churn keeps or recreates the shared daemon correctly" {
  if [ "${MOCK_NVML:-}" = "true" ]; then skip "requires real MPS daemon"; fi

  # While one claim keeps the GPU, other claims come and go on the same daemon.
  _start_mps_sleeper cs-mps-keeper
  kubectl wait --for=condition=READY pods cs-mps-keeper --timeout=300s
  local uid
  uid=$(_mps_daemon_uids)
  for i in $(seq 1 "${TEST_CS_MPS_CHURN_ITERATIONS}"); do
    _start_mps_sleeper "cs-mps-churn-${i}"
    kubectl wait --for=condition=READY pods "cs-mps-churn-${i}" --timeout=120s
    _delete_mps_pod "cs-mps-churn-${i}"
    assert_equal "$(_mps_daemon_uids)" "${uid}"
  done
  _delete_mps_pod cs-mps-keeper

  # The last claim goes away while the next one arrives: the next claim may
  # find the daemon terminating, and must get a new one once it is gone.
  # Start() waits for the old daemon, so this must not fall back to the
  # kubelet's retry about a minute later.
  local start
  for i in $(seq 1 "${TEST_CS_MPS_CHURN_ITERATIONS}"); do
    start=$SECONDS
    _start_mps_sleeper "cs-mps-flip-${i}"
    kubectl wait --for=condition=READY pods "cs-mps-flip-${i}" --timeout=180s
    echo "flip ${i}: ready after $(( SECONDS - start )) s"
    [ $(( SECONDS - start )) -le 45 ]
    kubectl delete pod "cs-mps-flip-${i}" --wait=false
  done

  kubectl delete pods,resourceclaimtemplates -l env=batssuite,test=cs-mps --timeout=120s
  _assert_no_mps_leak
}

# bats test_tags=consumable-shares,stress
@test "GPUs: ConsumableShares — matmul on 1 of 4 shares gets ~25% of the GPU even when it is idle" {
  if [ "${MOCK_NVML:-}" = "true" ]; then skip "requires real MPS daemon"; fi

  _start_matmul_pod cs-mps-mm-all 4 4Gi "0 30 1024 4608"
  _wait_succeeded cs-mps-mm-all
  local t4
  t4=$(_tflops cs-mps-mm-all)
  _delete_mps_pod cs-mps-mm-all

  _start_matmul_pod cs-mps-mm-one 1 2Gi "0 30 1024 2560"
  _wait_succeeded cs-mps-mm-one
  local t1
  t1=$(_tflops cs-mps-mm-one)
  echo "matmul alone: 4 shares -> ${t4} TFLOPS, 1 share -> ${t1} TFLOPS"
  # Kept for the 4-client test below.
  echo "${t4}" > "${BATS_FILE_TMPDIR}/t4"

  # Without the client limit, a lone client would use the whole GPU.
  _float_ok "${t1} / ${t4} >= 0.15 && ${t1} / ${t4} <= 0.40"

  # A claim cannot allocate past its consumed memory.
  run kubectl logs cs-mps-mm-one -c ctr
  assert_output --partial "ALLOC_1024MiB=OK"
  assert_output --partial "ALLOC_2560MiB=OOM"

  _delete_mps_pod cs-mps-mm-one
  _assert_no_mps_leak
}

# bats test_tags=consumable-shares,stress
@test "GPUs: ConsumableShares — concurrent matmul on 1 and 3 shares splits the GPU 1:3" {
  if [ "${MOCK_NVML:-}" = "true" ]; then skip "requires real MPS daemon"; fi

  local at=$(( $(date +%s) + 45 ))
  _start_matmul_pod cs-mps-mm-1 1 2Gi "${at} 60 1024 2560"
  _start_matmul_pod cs-mps-mm-3 3 4Gi "${at} 60 2048 4608"
  _wait_succeeded cs-mps-mm-1 cs-mps-mm-3

  local t1 t3
  t1=$(_tflops cs-mps-mm-1)
  t3=$(_tflops cs-mps-mm-3)
  echo "matmul together: 1 share -> ${t1} TFLOPS, 3 shares -> ${t3} TFLOPS"
  _float_ok "${t3} / ${t1} >= 2 && ${t3} / ${t1} <= 4.5"

  run kubectl logs cs-mps-mm-1 -c ctr
  assert_output --partial "ALLOC_2560MiB=OOM"
  run kubectl logs cs-mps-mm-3 -c ctr
  assert_output --partial "ALLOC_2048MiB=OK"
  assert_output --partial "ALLOC_4608MiB=OOM"

  kubectl delete pods,resourceclaimtemplates -l env=batssuite,test=cs-mps --timeout=120s
  _assert_no_mps_leak
}

# bats test_tags=consumable-shares,stress
@test "GPUs: ConsumableShares — 4 matmul clients saturate the GPU and share it evenly" {
  if [ "${MOCK_NVML:-}" = "true" ]; then skip "requires real MPS daemon"; fi

  local at=$(( $(date +%s) + 45 )) i
  for i in 1 2 3 4; do
    _start_matmul_pod "cs-mps-mm-q${i}" 1 2Gi "${at} 60 1024 2560"
  done
  _wait_succeeded cs-mps-mm-q{1,2,3,4}
  _mps_daemon_count_is 1

  local all=() sum
  for i in 1 2 3 4; do
    run kubectl logs "cs-mps-mm-q${i}" -c ctr
    assert_output --partial "MATMUL_DONE"
    all+=("$(_tflops "cs-mps-mm-q${i}")")
  done
  sum=$(IFS=+; awk "BEGIN { print ${all[*]} }")
  echo "matmul 4 clients: ${all[*]} TFLOPS (sum ${sum})"

  for i in "${all[@]}"; do
    _float_ok "${i} >= 0.6 * ${sum} / 4 && ${i} <= 1.4 * ${sum} / 4"
  done
  if [ -f "${BATS_FILE_TMPDIR}/t4" ]; then
    _float_ok "${sum} >= 0.6 * $(cat "${BATS_FILE_TMPDIR}/t4")"
  fi

  kubectl delete pods,resourceclaimtemplates -l env=batssuite,test=cs-mps --timeout=120s
  _assert_no_mps_leak
}
