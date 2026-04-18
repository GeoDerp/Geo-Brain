// Package orchestrator manages ephemeral Podman container lifecycle for
// package detonation sandboxes. It uses the Podman REST API (via unix socket)
// to create, start, inspect, and tear down network-isolated containers.
package orchestrator

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// Sandbox represents an ephemeral detonation container.
type Sandbox struct {
	ContainerID string
	PID         int
	CgroupPath  string
}

// Orchestrator manages Podman container lifecycle via the REST API.
type Orchestrator struct {
	SocketPath   string
	SandboxImage string
	client       *http.Client
}

// New creates a new Orchestrator connected to the Podman socket.
func New(socketPath, sandboxImage string) *Orchestrator {
	transport := &http.Transport{
		DialContext: func(_ context.Context, _, _ string) (net.Conn, error) {
			return net.Dial("unix", socketPath)
		},
	}
	return &Orchestrator{
		SocketPath:   socketPath,
		SandboxImage: sandboxImage,
		client: &http.Client{
			Transport: transport,
			Timeout:   30 * time.Second,
		},
	}
}

// ContainerCreateRequest is the Podman API container creation payload.
type ContainerCreateRequest struct {
	Image           string            `json:"image"`
	Name            string            `json:"name"`
	Command         []string          `json:"command,omitempty"`
	Env             map[string]string `json:"env,omitempty"`
	Mounts          []Mount           `json:"mounts,omitempty"`
	NetNS           Namespace         `json:"netns,omitempty"`
	ReadOnlyFS      bool              `json:"read_only_filesystem"`
	NoNewPrivileges bool              `json:"no_new_privileges"`
	CapDrop         []string          `json:"cap_drop,omitempty"`
	ResourceLimits  *ResourceLimits   `json:"resource_limits,omitempty"`
}

// Mount represents a container bind mount.
type Mount struct {
	Type        string   `json:"type"`
	Source      string   `json:"source"`
	Destination string   `json:"destination"`
	Options     []string `json:"options,omitempty"`
}

// Namespace configures the container network namespace.
type Namespace struct {
	NSMode string `json:"nsmode"`
}

// ResourceLimits constrains sandbox resource usage.
type ResourceLimits struct {
	Memory *MemoryLimit `json:"memory,omitempty"`
	CPU    *CPULimit    `json:"cpu,omitempty"`
}

// MemoryLimit constrains sandbox memory.
type MemoryLimit struct {
	Limit int64 `json:"limit"` // bytes
}

// CPULimit constrains sandbox CPU.
type CPULimit struct {
	Quota  int64 `json:"quota"`
	Period uint64 `json:"period"`
}

// SpinUp creates and starts an ephemeral, network-isolated sandbox container
// with the package tarball mounted inside. Returns the Sandbox metadata for
// tracing and teardown.
func (o *Orchestrator) SpinUp(ctx context.Context, pkgPath, pkgType string) (*Sandbox, error) {
	containerName := fmt.Sprintf("pkg-sentinel-sandbox-%d", time.Now().UnixNano())

	// Use the explicit package filename to avoid glob injection
	pkgFilename := filepath.Base(pkgPath)

	// Determine the installation command based on package type
	var cmd []string
	switch strings.ToLower(pkgType) {
	case "npm", "tgz":
		cmd = []string{"sh", "-c", fmt.Sprintf("cd /sandbox && npm install --ignore-scripts %q 2>&1; ls -la node_modules/ 2>/dev/null || true", pkgFilename)}
	case "pypi", "whl":
		cmd = []string{"sh", "-c", fmt.Sprintf("cd /sandbox && pip install --no-deps %q 2>&1 || true", pkgFilename)}
	case "maven", "jar":
		cmd = []string{"sh", "-c", fmt.Sprintf("cd /sandbox && jar -tf %q 2>&1 || true", pkgFilename)}
	default:
		cmd = []string{"sh", "-c", "ls -la /sandbox/"}
	}

	createReq := ContainerCreateRequest{
		Image:           o.SandboxImage,
		Name:            containerName,
		Command:         cmd,
		ReadOnlyFS:      false, // needs write for install
		NoNewPrivileges: true,
		CapDrop:         []string{"ALL"},
		NetNS:           Namespace{NSMode: "none"}, // full network isolation
		Mounts: []Mount{
			{
				Type:        "bind",
				Source:      filepath.Dir(pkgPath),
				Destination: "/sandbox",
				Options:     []string{"ro"},
			},
		},
		ResourceLimits: &ResourceLimits{
			Memory: &MemoryLimit{Limit: 256 * 1024 * 1024}, // 256MB
			CPU:    &CPULimit{Quota: 50000, Period: 100000}, // 50% of one core
		},
	}

	body, err := json.Marshal(createReq)
	if err != nil {
		return nil, fmt.Errorf("marshal create request: %w", err)
	}

	// Create the container
	createResp, err := o.podmanAPI(ctx, "POST", "/v4.0.0/libpod/containers/create", body)
	if err != nil {
		return nil, fmt.Errorf("create container: %w", err)
	}
	defer func() {
		_ = createResp.Body.Close()
	}()

	if createResp.StatusCode != http.StatusCreated {
		respBody, _ := io.ReadAll(createResp.Body)
		return nil, fmt.Errorf("create container failed (%d): %s", createResp.StatusCode, string(respBody))
	}

	var createResult struct {
		ID string `json:"Id"`
	}
	if err := json.NewDecoder(createResp.Body).Decode(&createResult); err != nil {
		return nil, fmt.Errorf("decode create response: %w", err)
	}

	containerID := createResult.ID
	log.Printf("[orchestrator] created sandbox container: %s (%s)", containerName, containerID[:12])

	// Start the container
	startResp, err := o.podmanAPI(ctx, "POST", fmt.Sprintf("/v4.0.0/libpod/containers/%s/start", containerID), nil)
	if err != nil {
		_ = o.removeContainer(context.Background(), containerID)
		return nil, fmt.Errorf("start container: %w", err)
	}
	_ = startResp.Body.Close()

	if startResp.StatusCode != http.StatusNoContent && startResp.StatusCode != http.StatusOK {
		_ = o.removeContainer(context.Background(), containerID)
		return nil, fmt.Errorf("start container failed: %d", startResp.StatusCode)
	}

	// Inspect to get PID and cgroup path
	pid, cgroupPath, err := o.inspectContainer(ctx, containerID)
	if err != nil {
		_ = o.removeContainer(context.Background(), containerID)
		return nil, fmt.Errorf("inspect container: %w", err)
	}

	return &Sandbox{
		ContainerID: containerID,
		PID:         pid,
		CgroupPath:  cgroupPath,
	}, nil
}

// Teardown stops and removes the sandbox container and cleans up mounted
// package data from the RAM disk.
func (o *Orchestrator) Teardown(ctx context.Context, sb *Sandbox, pkgDir string) {
	log.Printf("[orchestrator] tearing down sandbox %s", sb.ContainerID[:12])

	// Stop the container (5 second grace period)
	stopResp, err := o.podmanAPI(ctx, "POST", fmt.Sprintf("/v4.0.0/libpod/containers/%s/stop?timeout=5", sb.ContainerID), nil)
	if err != nil {
		log.Printf("[orchestrator] stop error: %v", err)
	} else {
		_ = stopResp.Body.Close()
	}

	// Remove the container
	if err := o.removeContainer(ctx, sb.ContainerID); err != nil {
		log.Printf("[orchestrator] remove error: %v", err)
	}

	// Clean up RAM disk package data
	if pkgDir != "" {
		if err := os.RemoveAll(pkgDir); err != nil {
			log.Printf("[orchestrator] cleanup error for %s: %v", pkgDir, err)
		}
	}
}

// inspectContainer retrieves the PID and cgroup path of a running container.
func (o *Orchestrator) inspectContainer(ctx context.Context, containerID string) (int, string, error) {
	resp, err := o.podmanAPI(ctx, "GET", fmt.Sprintf("/v4.0.0/libpod/containers/%s/json", containerID), nil)
	if err != nil {
		return 0, "", err
	}
	defer func() {
		_ = resp.Body.Close()
	}()

	var inspectResult struct {
		State struct {
			Pid int `json:"Pid"`
		} `json:"State"`
		HostConfig struct {
			CgroupParent string `json:"CgroupParent"`
		} `json:"HostConfig"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&inspectResult); err != nil {
		return 0, "", fmt.Errorf("decode inspect: %w", err)
	}

	return inspectResult.State.Pid, inspectResult.HostConfig.CgroupParent, nil
}

// removeContainer force-removes a container by ID.
func (o *Orchestrator) removeContainer(ctx context.Context, containerID string) error {
	resp, err := o.podmanAPI(ctx, "DELETE", fmt.Sprintf("/v4.0.0/libpod/containers/%s?force=true&v=true", containerID), nil)
	if err != nil {
		return err
	}
	_ = resp.Body.Close()
	return nil
}

// podmanAPI performs an HTTP request against the Podman REST API socket.
func (o *Orchestrator) podmanAPI(ctx context.Context, method, path string, body []byte) (*http.Response, error) {
	url := "http://d" + path // "d" is a dummy host for unix socket

	var bodyReader io.Reader
	if body != nil {
		bodyReader = strings.NewReader(string(body))
	}

	req, err := http.NewRequestWithContext(ctx, method, url, bodyReader)
	if err != nil {
		return nil, err
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}

	return o.client.Do(req)
}
