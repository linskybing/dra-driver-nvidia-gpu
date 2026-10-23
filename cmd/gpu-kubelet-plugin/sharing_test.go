/*
 * Copyright 2026 The Kubernetes Authors.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package main

import (
	"context"
	"errors"
	"fmt"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/require"
	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/util/validation"
	k8sfake "k8s.io/client-go/kubernetes/fake"
	"k8s.io/utils/ptr"

	configapi "sigs.k8s.io/dra-driver-nvidia-gpu/api/nvidia.com/resource/v1beta1"
	pkgflags "sigs.k8s.io/dra-driver-nvidia-gpu/pkg/flags"
)

// mockFileChecker implements fileChecker for tests.
// existingPath is the single path Stat should report as existing; empty means nothing exists.
type mockFileChecker struct {
	existingPath string
}

func (m *mockFileChecker) Stat(path string) error {
	if path == m.existingPath {
		return nil
	}
	return errors.New("not found")
}

func TestSetMpsShmMountPath(t *testing.T) {
	testCases := map[string]struct {
		existingPath      string
		expectedMountPath string
	}{
		// /dev/shm exists under the driver root → daemon uses chroot → shm at <driverRootMountDir>/dev/shm.
		"dev/shm exists under driver root": {
			existingPath:      filepath.Join(driverRootMountDir, "dev", "shm"),
			expectedMountPath: filepath.Join(driverRootMountDir, "dev", "shm"),
		},
		// /dev/shm not present under driver root (e.g. GKE COS) → daemon runs directly
		// in the container namespace → shm at /dev/shm.
		"dev/shm does not exist under driver root — case for GKE COS": {
			existingPath:      "",
			expectedMountPath: MpsDefaultShmMountPath,
		},
	}

	for name, tc := range testCases {
		t.Run(name, func(t *testing.T) {
			checker := &mockFileChecker{existingPath: tc.existingPath}
			require.Equal(t, tc.expectedMountPath, setMpsShmMountPath(checker))
		})
	}
}

func TestRenderMpsControlDaemonDeploymentImagePullSettings(t *testing.T) {
	deployment, err := renderMpsControlDaemonDeployment(
		filepath.Join("..", "..", "templates", "mps-control-daemon.tmpl.yaml"),
		MpsControlDaemonTemplateData{
			NodeName:                  "node-a",
			MpsControlDaemonNamespace: "dra-driver-nvidia-gpu",
			MpsControlDaemonName:      "mps-control-daemon-test",
			CUDA_VISIBLE_DEVICES:      "GPU-0",
			NvidiaDriverRoot:          "/",
			MpsShmDirectory:           "/var/lib/kubelet/plugins/gpu.nvidia.com/mps/test/shm",
			MpsPipeDirectory:          "/var/lib/kubelet/plugins/gpu.nvidia.com/mps/test/pipe",
			MpsLogDirectory:           "/var/lib/kubelet/plugins/gpu.nvidia.com/mps/test/log",
			MpsImageName:              "registry.example.com/dra-driver:dev",
			MpsImagePullPolicy:        "Always",
			MpsImagePullSecretNames:   []string{"regcred", "mirrorcred"},
			MpsShmMountPath:           MpsDefaultShmMountPath,
		},
	)
	require.NoError(t, err)

	require.Equal(t, []corev1.LocalObjectReference{
		{Name: "regcred"},
		{Name: "mirrorcred"},
	}, deployment.Spec.Template.Spec.ImagePullSecrets)
	require.Len(t, deployment.Spec.Template.Spec.Containers, 1)
	require.Equal(t, corev1.PullAlways, deployment.Spec.Template.Spec.Containers[0].ImagePullPolicy)
}

func newTestMpsManager(t *testing.T, deployments ...*appsv1.Deployment) *MpsManager {
	clientset := k8sfake.NewSimpleClientset()
	for _, d := range deployments {
		_, err := clientset.AppsV1().Deployments(d.Namespace).Create(context.Background(), d, metav1.CreateOptions{})
		require.NoError(t, err)
	}
	cfg := &Config{
		flags:      &Flags{nodeName: "node-a", namespace: "dra-driver"},
		clientsets: pkgflags.ClientSets{Core: clientset},
	}
	return NewMpsManager(cfg, nil, "/", MpsControlDaemonTemplatePath)
}

func newTestMpsDeployment(namespace, name, nodeName string) *appsv1.Deployment {
	return &appsv1.Deployment{
		ObjectMeta: metav1.ObjectMeta{Namespace: namespace, Name: name},
		Spec: appsv1.DeploymentSpec{
			Template: corev1.PodTemplateSpec{Spec: corev1.PodSpec{NodeName: nodeName}},
		},
	}
}

func TestMpsControlDaemonStartWithExistingDeployment(t *testing.T) {
	config := &configapi.MpsConfig{DefaultActiveThreadPercentage: ptr.To(50)}
	configHash, err := mpsConfigHash(config)
	require.NoError(t, err)
	otherHash, err := mpsConfigHash(&configapi.MpsConfig{DefaultActiveThreadPercentage: ptr.To(25)})
	require.NoError(t, err)

	testCases := map[string]struct {
		annotations map[string]string
		terminating bool
		expectedErr string
	}{
		"same config is reused": {
			annotations: map[string]string{MpsConfigHashAnnotation: configHash},
		},
		"daemon without config hash is reused": {},
		"different config is rejected": {
			annotations: map[string]string{MpsConfigHashAnnotation: otherHash},
			expectedErr: "different MPS configuration",
		},
		"terminating daemon is rejected": {
			annotations: map[string]string{MpsConfigHashAnnotation: configHash},
			terminating: true,
			expectedErr: "is terminating",
		},
	}

	for name, tc := range testCases {
		t.Run(name, func(t *testing.T) {
			devices := AllocatableDevices{"gpu-0": &AllocatableDevice{Gpu: &GpuInfo{UUID: "GPU-0"}}}
			manager := newTestMpsManager(t)
			daemon := manager.NewMpsControlDaemon("test-daemon", devices)

			deployment := newTestMpsDeployment(daemon.namespace, daemon.name, "node-a")
			deployment.Annotations = tc.annotations
			if tc.terminating {
				deployment.DeletionTimestamp = ptr.To(metav1.Now())
			}
			_, err := manager.config.clientsets.Core.AppsV1().Deployments(daemon.namespace).Create(context.Background(), deployment, metav1.CreateOptions{})
			require.NoError(t, err)

			// An existing daemon returns before any host-side setup, so this needs no GPU.
			err = daemon.Start(context.Background(), config)
			if tc.expectedErr == "" {
				require.NoError(t, err)
				return
			}
			require.ErrorContains(t, err, tc.expectedErr)
		})
	}
}

func TestDeleteNodeControlDaemons(t *testing.T) {
	manager := newTestMpsManager(t,
		newTestMpsDeployment("dra-driver", "mps-control-daemon-a", "node-a"),
		newTestMpsDeployment("dra-driver", "mps-control-daemon-b", "node-b"),
		newTestMpsDeployment("dra-driver", "dra-driver-controller", "node-a"),
		newTestMpsDeployment("other", "mps-control-daemon-c", "node-a"),
	)

	require.NoError(t, manager.DeleteNodeControlDaemons(context.Background()))

	var remaining []string
	for _, namespace := range []string{"dra-driver", "other"} {
		list, err := manager.config.clientsets.Core.AppsV1().Deployments(namespace).List(context.Background(), metav1.ListOptions{})
		require.NoError(t, err)
		for _, d := range list.Items {
			remaining = append(remaining, d.Namespace+"/"+d.Name)
		}
	}
	require.ElementsMatch(t, []string{
		"dra-driver/mps-control-daemon-b",
		"dra-driver/dra-driver-controller",
		"other/mps-control-daemon-c",
	}, remaining)
}

func TestSharedMpsControlDaemonID(t *testing.T) {
	nodeA := newTestMpsManager(t)
	nodeB := newTestMpsManager(t)
	nodeB.config.flags.nodeName = "node-b"

	id := nodeA.SharedMpsControlDaemonID("GPU-0")
	require.Equal(t, id, nodeA.SharedMpsControlDaemonID("GPU-0"), "all claims on a device must find the same daemon")
	require.NotEqual(t, id, nodeA.SharedMpsControlDaemonID("GPU-1"))
	require.NotEqual(t, id, nodeB.SharedMpsControlDaemonID("GPU-0"))
	require.NotEqual(t, id, nodeA.SharedMpsControlDaemonID("MIG-GPU-0/1/0"))

	// The ID ends up in Deployment names and label values.
	require.Empty(t, validation.IsDNS1123Label(fmt.Sprintf(MpsControlDaemonNameFmt, nodeA.SharedMpsControlDaemonID("MIG-GPU-0/1/0"))))
}
