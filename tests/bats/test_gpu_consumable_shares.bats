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
}

setup() {
  load 'helpers.sh'
  _common_setup
  log_objects
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
  kubectl delete -f "${_specpath}"
  kubectl wait --for=delete pods "pod-share-mps-1" --timeout=30s
  kubectl wait --for=delete -n "${_ns}" "deployment/${_name}" --timeout=60s
}
