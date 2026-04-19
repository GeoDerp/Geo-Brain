package orchestrator

import (
	"context"
	"os"
	"testing"
)

// NOTE: This test requires a running Podman socket.
func TestRunSandboxContainer(t *testing.T) {
	if os.Getenv("PODMAN_SOCK") == "" {
		t.Skip("PODMAN_SOCK not set, skipping integration test")
	}

	ctx := context.Background()
	image := "docker.io/library/alpine:latest"
	cmd := []string{"echo", "hello world"}

	output, err := RunSandboxContainer(ctx, image, cmd)
	if err != nil {
		t.Fatalf("RunSandboxContainer() failed: %v", err)
	}

	expected := "hello world
"
	if string(output) != expected {
		t.Errorf("RunSandboxContainer() output = %q, want %q", string(output), expected)
	}
}
