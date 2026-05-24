// Package main implements the pkg-sentinel reverse proxy server. It
// intercepts package download requests from npm, PyPI, and Maven clients,
// detonates packages in ephemeral Podman sandboxes, and evaluates Azazel
// eBPF telemetry against strict exfiltration rules before serving or
// blocking the response.
package main

import (
	"context"
	"crypto/sha256"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/stig-homelab/pkg-sentinel/analyzer"
	"github.com/stig-homelab/pkg-sentinel/config"
	"github.com/stig-homelab/pkg-sentinel/orchestrator"
	"github.com/stig-homelab/pkg-sentinel/rules"
)

func main() {
	cfg, err := config.Load()
	if err != nil {
		log.Fatalf("[pkg-sentinel] configuration error: %v", err)
	}

	// Ensure RAM disk directory exists
	if err := os.MkdirAll(cfg.RAMDiskPath, 0o700); err != nil {
		log.Fatalf("[pkg-sentinel] failed to create RAM disk path %s: %v", cfg.RAMDiskPath, err)
	}

	orch := orchestrator.New(cfg.PodmanSocketPath, cfg.SandboxImage)

	mux := http.NewServeMux()

	// Health endpoint for container healthcheck
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"status":"ok"}`))
	})

	// Registry proxy endpoints
	mux.Handle("/npm/", newRegistryHandler(cfg, orch, "npm", cfg.NPMRegistryUpstream))
	mux.Handle("/pypi/", newRegistryHandler(cfg, orch, "pypi", cfg.PyPIRegistryUpstream))
	mux.Handle("/maven/", newRegistryHandler(cfg, orch, "maven", cfg.MavenRegistryUpstream))

	// Root handler with usage info
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"service":"pkg-sentinel","version":"1.0.0","endpoints":["/npm/","/pypi/","/maven/","/healthz"]}`))
	})

	srv := &http.Server{
		Addr:              cfg.ListenAddr,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      cfg.DetonationTimeout + 30*time.Second, // allow for detonation
		IdleTimeout:       120 * time.Second,
	}

	// Graceful shutdown
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	go func() {
		log.Printf("[pkg-sentinel] listening on %s (timeout=%s, default_action=%s)",
			cfg.ListenAddr, cfg.DetonationTimeout, cfg.DefaultAction)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("[pkg-sentinel] server error: %v", err)
		}
	}()

	<-ctx.Done()
	log.Println("[pkg-sentinel] shutting down...")

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		log.Printf("[pkg-sentinel] shutdown error: %v", err)
	}
}

// registryHandler proxies requests to an upstream package registry and
// intercepts package archive downloads for sandbox detonation.
type registryHandler struct {
	cfg          *config.Config
	orch         *orchestrator.Orchestrator
	registryType string
	upstream     *url.URL
	proxy        *httputil.ReverseProxy
}

// newRegistryHandler creates a handler that proxies to the given upstream
// registry, intercepting package downloads for detonation analysis.
func newRegistryHandler(cfg *config.Config, orch *orchestrator.Orchestrator, registryType, upstreamURL string) http.Handler {
	upstream, err := url.Parse(upstreamURL)
	if err != nil {
		log.Fatalf("[pkg-sentinel] invalid upstream URL for %s: %v", registryType, err)
	}

	proxy := httputil.NewSingleHostReverseProxy(upstream)

	// Preserve the original director and strip our prefix
	originalDirector := proxy.Director
	prefix := "/" + registryType
	proxy.Director = func(req *http.Request) {
		req.URL.Path = strings.TrimPrefix(req.URL.Path, prefix)
		if req.URL.Path == "" {
			req.URL.Path = "/"
		}
		originalDirector(req)
		req.Host = upstream.Host
	}

	return &registryHandler{
		cfg:          cfg,
		orch:         orch,
		registryType: registryType,
		upstream:     upstream,
		proxy:        proxy,
	}
}

func (h *registryHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	// Only intercept GET requests for package archives
	if r.Method != http.MethodGet || !isPackageArchive(r.URL.Path) {
		// Pass through metadata/search/non-archive requests directly
		h.proxy.ServeHTTP(w, r)
		return
	}

	log.Printf("[pkg-sentinel] intercepting %s package download: %s", h.registryType, r.URL.Path)

	// Step 1: Fetch the package to the RAM disk
	pkgDir, pkgPath, err := h.fetchPackage(r)
	if err != nil {
		log.Printf("[pkg-sentinel] fetch error: %v", err)
		http.Error(w, "upstream fetch failed", http.StatusBadGateway)
		return
	}

	// Step 2: Detonate in sandbox with timeout
	detonationCtx, cancel := context.WithTimeout(r.Context(), h.cfg.DetonationTimeout)
	defer cancel()

	result, err := h.detonate(detonationCtx, pkgPath, pkgDir)
	if err != nil {
		log.Printf("[pkg-sentinel] detonation error: %v", err)
		// On error, apply default action
		if h.cfg.DefaultAction == "allow" {
			log.Printf("[pkg-sentinel] default action: ALLOW (detonation failed)")
			h.serveCachedPackage(w, pkgPath)
		} else {
			log.Printf("[pkg-sentinel] default action: BLOCK (detonation failed)")
			_ = os.RemoveAll(pkgDir)
			http.Error(w, "package detonation failed — blocked by policy", http.StatusForbidden)
		}
		return
	}

	// Step 3: Enforce verdict
	if result.Safe {
		log.Printf("[pkg-sentinel] SAFE: %s (%d events, %s)", r.URL.Path, result.EventCount, result.Duration)
		h.serveCachedPackage(w, pkgPath)
	} else {
		log.Printf("[pkg-sentinel] BLOCKED: %s (%d violations)", r.URL.Path, len(result.Violations))
		for _, v := range result.Violations {
			log.Printf("[pkg-sentinel]   [%s] %s", v.Rule, v.Reason)
		}
		_ = os.RemoveAll(pkgDir)
		http.Error(w, "package blocked: supply chain threat detected", http.StatusForbidden)
	}
}

// fetchPackage downloads the package from the upstream registry to the RAM
// disk and returns the directory and file path.
func (h *registryHandler) fetchPackage(r *http.Request) (string, string, error) {
	// Build upstream URL
	upstreamPath := strings.TrimPrefix(r.URL.Path, "/"+h.registryType)
	upstreamURL := h.upstream.String() + upstreamPath

	req, err := http.NewRequestWithContext(r.Context(), http.MethodGet, upstreamURL, nil)
	if err != nil {
		return "", "", fmt.Errorf("create upstream request: %w", err)
	}

	// Forward auth headers if present
	if auth := r.Header.Get("Authorization"); auth != "" {
		req.Header.Set("Authorization", auth)
	}

	client := &http.Client{Timeout: 60 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return "", "", fmt.Errorf("upstream request: %w", err)
	}
	defer func() {
		_ = resp.Body.Close()
	}()

	if resp.StatusCode != http.StatusOK {
		return "", "", fmt.Errorf("upstream returned %d", resp.StatusCode)
	}

	// Create a unique directory on the RAM disk
	hash := sha256.Sum256([]byte(r.URL.Path + fmt.Sprintf("%d", time.Now().UnixNano())))
	dirName := fmt.Sprintf("%x", hash[:8])
	pkgDir := filepath.Join(h.cfg.RAMDiskPath, dirName)
	if err := os.MkdirAll(pkgDir, 0o700); err != nil {
		return "", "", fmt.Errorf("create pkg dir: %w", err)
	}

	// Determine filename from URL path — sanitize to prevent path traversal
	filename := filepath.Base(upstreamPath)
	if filename == "" || filename == "." || filename == ".." {
		filename = "package.tar.gz"
	}
	// Strip any remaining path separators or traversal sequences
	filename = strings.ReplaceAll(filename, "/", "_")
	filename = strings.ReplaceAll(filename, "\\", "_")
	filename = strings.ReplaceAll(filename, "..", "_")

	pkgPath := filepath.Join(pkgDir, filename)
	// Verify the resolved path is within the expected directory
	if !strings.HasPrefix(filepath.Clean(pkgPath), filepath.Clean(pkgDir)) {
		return "", "", fmt.Errorf("path traversal detected in filename: %s", filename)
	}
	f, err := os.Create(pkgPath)
	if err != nil {
		return "", "", fmt.Errorf("create pkg file: %w", err)
	}
	defer func() {
		_ = f.Close()
	}()

	if _, err := io.Copy(f, resp.Body); err != nil {
		_ = os.RemoveAll(pkgDir)
		return "", "", fmt.Errorf("download package: %w", err)
	}

	return pkgDir, pkgPath, nil
}

// detonate runs the package through the sandbox and Azazel analysis pipeline.
func (h *registryHandler) detonate(ctx context.Context, pkgPath, pkgDir string) (*analyzer.Result, error) {
	// Resolve upstream registry IPs for the rule engine allow-list
	allowedIPs := resolveRegistryIPs(h.upstream.Hostname())

	ruleEngine := rules.NewEngine(allowedIPs, "/sandbox")
	az := analyzer.New(h.cfg.AzazelBinary, ruleEngine, h.cfg.LLMEndpoint, h.cfg.LLMModel)

	// Spin up the ephemeral sandbox container
	sandbox, err := h.orch.SpinUp(ctx, pkgPath, h.registryType)
	if err != nil {
		return nil, fmt.Errorf("spin up sandbox: %w", err)
	}
	defer h.orch.Teardown(context.Background(), sandbox, pkgDir)

	// Attach Azazel and trace
	result, err := az.Trace(ctx, sandbox.PID, sandbox.CgroupPath)
	if err != nil {
		return nil, fmt.Errorf("azazel trace: %w", err)
	}

	return result, nil
}

// serveCachedPackage streams the cached package file back to the client.
func (h *registryHandler) serveCachedPackage(w http.ResponseWriter, pkgPath string) {
	// Validate the path is within the RAM disk to prevent path traversal
	cleanPath := filepath.Clean(pkgPath)
	if !strings.HasPrefix(cleanPath, filepath.Clean(h.cfg.RAMDiskPath)) {
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	f, err := os.Open(cleanPath)
	if err != nil {
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	defer func() {
		_ = f.Close()
		// Clean up after serving
		_ = os.RemoveAll(filepath.Dir(cleanPath))
	}()

	stat, err := f.Stat()
	if err != nil {
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Content-Length", fmt.Sprintf("%d", stat.Size()))
	w.WriteHeader(http.StatusOK)
	_, _ = io.Copy(w, f)
}

// isPackageArchive returns true if the request path looks like a package
// archive download (vs. metadata/search/API requests).
func isPackageArchive(path string) bool {
	lower := strings.ToLower(path)
	return strings.HasSuffix(lower, ".tgz") ||
		strings.HasSuffix(lower, ".tar.gz") ||
		strings.HasSuffix(lower, ".whl") ||
		strings.HasSuffix(lower, ".jar") ||
		strings.HasSuffix(lower, ".zip") ||
		strings.HasSuffix(lower, ".egg") ||
		strings.HasSuffix(lower, ".gem") ||
		strings.HasSuffix(lower, ".nupkg")
}

// resolveRegistryIPs does a DNS lookup on the registry hostname and returns
// the resulting IP addresses as strings for the rule engine allow-list.
func resolveRegistryIPs(hostname string) []string {
	// Include common CDN/registry IPs as a baseline
	ips := []string{}

	// Attempt DNS resolution (best-effort; may fail in air-gapped envs)
	addrs, err := (&net.Resolver{}).LookupHost(context.Background(), hostname)
	if err != nil {
		log.Printf("[pkg-sentinel] DNS lookup for %s failed (using empty allow-list): %v", hostname, err)
		return ips
	}

	return append(ips, addrs...)
}
