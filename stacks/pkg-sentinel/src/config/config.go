// Package config provides application-wide configuration management for
// pkg-sentinel. All tunables are driven by environment variables, matching
// the Geo-Brain convention of declarative, .env-driven deployments.
package config

import (
	"fmt"
	"os"
	"strings"
	"time"
)

// Config holds the runtime configuration for the pkg-sentinel proxy.
type Config struct {
	// ListenAddr is the address the proxy listens on (e.g. ":8443").
	ListenAddr string

	// DetonationTimeout is the maximum wall-clock time allowed for sandbox
	// detonation before the proxy enforces DefaultAction.
	DetonationTimeout time.Duration

	// DefaultAction controls the fallback when detonation times out.
	// Valid values: "block" (HTTP 403) or "allow" (HTTP 200).
	DefaultAction string

	// AzazelBinary is the filesystem path to the Azazel eBPF tracer binary.
	AzazelBinary string

	// PodmanSocketPath is the path to the rootless Podman API socket.
	PodmanSocketPath string

	// SandboxImage is the OCI image used for ephemeral detonation containers.
	SandboxImage string

	// LLMEndpoint is the optional HTTP/JSON webhook for the local AI inference
	// endpoint used by the heuristics engine for deeper behavioral analysis.
	LLMEndpoint string

	// RAMDiskPath is the path to the tmpfs / RAM-backed directory used to
	// temporarily cache downloaded packages before detonation.
	RAMDiskPath string

	// NPMRegistryUpstream is the upstream npm registry URL.
	NPMRegistryUpstream string

	// PyPIRegistryUpstream is the upstream PyPI registry URL.
	PyPIRegistryUpstream string

	// MavenRegistryUpstream is the upstream Maven Central URL.
	MavenRegistryUpstream string
}

// Load reads configuration from environment variables with sensible defaults.
func Load() (*Config, error) {
	cfg := &Config{
		ListenAddr:           envOrDefault("PKG_SENTINEL_LISTEN", ":8443"),
		DefaultAction:        strings.ToLower(envOrDefault("PKG_SENTINEL_DEFAULT_ACTION", "block")),
		AzazelBinary:         envOrDefault("PKG_SENTINEL_AZAZEL_BIN", "/usr/local/bin/azazel"),
		PodmanSocketPath:     envOrDefault("PKG_SENTINEL_PODMAN_SOCK", "/run/podman/podman.sock"),
		SandboxImage:         envOrDefault("PKG_SENTINEL_SANDBOX_IMAGE", "docker.io/library/node:20-alpine"),
		LLMEndpoint:          os.Getenv("PKG_SENTINEL_LLM_ENDPOINT"),
		RAMDiskPath:          envOrDefault("PKG_SENTINEL_RAMDISK", "/dev/shm/pkg-sentinel"),
		NPMRegistryUpstream:  envOrDefault("PKG_SENTINEL_NPM_UPSTREAM", "https://registry.npmjs.org"),
		PyPIRegistryUpstream: envOrDefault("PKG_SENTINEL_PYPI_UPSTREAM", "https://pypi.org"),
		MavenRegistryUpstream: envOrDefault("PKG_SENTINEL_MAVEN_UPSTREAM", "https://repo1.maven.org/maven2"),
	}

	timeout := envOrDefault("PKG_SENTINEL_TIMEOUT", "15s")
	d, err := time.ParseDuration(timeout)
	if err != nil {
		return nil, fmt.Errorf("invalid PKG_SENTINEL_TIMEOUT %q: %w", timeout, err)
	}
	cfg.DetonationTimeout = d

	if cfg.DefaultAction != "block" && cfg.DefaultAction != "allow" {
		return nil, fmt.Errorf("PKG_SENTINEL_DEFAULT_ACTION must be 'block' or 'allow', got %q", cfg.DefaultAction)
	}

	return cfg, nil
}

func envOrDefault(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
