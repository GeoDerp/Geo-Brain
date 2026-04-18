// Package rules implements the exfiltration detection engine. It parses
// Azazel eBPF telemetry (NDJSON events) and evaluates four strict rules
// designed to detect information exfiltration during package detonation.
package rules

import (
	"fmt"
	"net"
	"strings"
)

// Verdict is the outcome of evaluating a single telemetry event.
type Verdict struct {
	Blocked bool   // true if the event triggered a rule violation
	Rule    string // rule identifier (e.g. "EXFIL-001")
	Reason  string // human-readable explanation
}

// TelemetryEvent represents a single Azazel NDJSON telemetry record.
type TelemetryEvent struct {
	Timestamp string `json:"timestamp"`
	PID       int    `json:"pid"`
	Syscall   string `json:"syscall"`
	// File I/O fields
	Path string `json:"path,omitempty"`
	// Network fields
	RemoteAddr string `json:"remote_addr,omitempty"`
	RemotePort int    `json:"remote_port,omitempty"`
	SockType   string `json:"sock_type,omitempty"`
	// Process execution fields
	Exec string   `json:"exec,omitempty"`
	Args []string `json:"args,omitempty"`
	// Environment fields
	EnvKey string `json:"env_key,omitempty"`
}

// Engine is the modular rule evaluation engine. It holds registry-specific
// allow-lists and applies each rule in order.
type Engine struct {
	// AllowedRegistryIPs is the set of IPs that are permitted for outbound
	// connections (i.e. the official package registry endpoints).
	AllowedRegistryIPs map[string]bool
	// WorkingDirectory is the expected package working directory inside the
	// sandbox container. File accesses outside this path are flagged.
	WorkingDirectory string
}

// NewEngine creates a new rule engine with the given allowed registry IPs
// and sandbox working directory.
func NewEngine(allowedIPs []string, workDir string) *Engine {
	ipSet := make(map[string]bool, len(allowedIPs))
	for _, ip := range allowedIPs {
		ipSet[ip] = true
	}
	return &Engine{
		AllowedRegistryIPs: ipSet,
		WorkingDirectory:   workDir,
	}
}

// Evaluate runs all four exfiltration rules against a single telemetry event
// and returns a Verdict. The first matching rule short-circuits evaluation.
func (e *Engine) Evaluate(ev TelemetryEvent) Verdict {
	if v := e.ruleSensitiveFileReads(ev); v.Blocked {
		return v
	}
	if v := e.ruleAnomalousNetworkEgress(ev); v.Blocked {
		return v
	}
	if v := e.ruleExfiltrationViaExecution(ev); v.Blocked {
		return v
	}
	if v := e.ruleEnvVarHarvesting(ev); v.Blocked {
		return v
	}
	return Verdict{Blocked: false}
}

// --- Rule 1: Sensitive File Reads (EXFIL-001) ---

// sensitivePathPrefixes are filesystem paths that indicate credential or
// identity file access outside the package sandbox.
var sensitivePathPrefixes = []string{
	"/.ssh/",
	"/.aws/",
	"/.kube/",
	"/.npmrc",
	"/.docker/config.json",
}

// sensitiveExactPaths are files that must never be read by a package install.
var sensitiveExactPaths = map[string]bool{
	"/etc/shadow":  true,
	"/etc/passwd":  true,
	"/etc/hosts":   true,
	"/etc/resolv.conf": true,
}

// sensitiveFilenames are filenames that indicate credential harvesting
// regardless of their directory location.
var sensitiveFilenames = map[string]bool{
	".env":            true,
	".npmrc":          true,
	"credentials":     true,
	"config.json":     true,
}

func (e *Engine) ruleSensitiveFileReads(ev TelemetryEvent) Verdict {
	syscall := strings.ToLower(ev.Syscall)
	if syscall != "open" && syscall != "openat" && syscall != "read" {
		return Verdict{}
	}
	if ev.Path == "" {
		return Verdict{}
	}

	path := ev.Path

	// Check if the path is outside the sandbox working directory
	if e.WorkingDirectory != "" && !strings.HasPrefix(path, e.WorkingDirectory) {
		// Check sensitive exact paths
		if sensitiveExactPaths[path] {
			return Verdict{
				Blocked: true,
				Rule:    "EXFIL-001",
				Reason:  fmt.Sprintf("sensitive file access: %s (syscall: %s)", path, ev.Syscall),
			}
		}

		// Check sensitive path prefixes (home directory patterns)
		for _, prefix := range sensitivePathPrefixes {
			if strings.Contains(path, prefix) {
				return Verdict{
					Blocked: true,
					Rule:    "EXFIL-001",
					Reason:  fmt.Sprintf("sensitive directory access: %s (syscall: %s)", path, ev.Syscall),
				}
			}
		}

		// Check sensitive filenames
		parts := strings.Split(path, "/")
		if len(parts) > 0 {
			basename := parts[len(parts)-1]
			if sensitiveFilenames[basename] {
				return Verdict{
					Blocked: true,
					Rule:    "EXFIL-001",
					Reason:  fmt.Sprintf("sensitive filename access: %s (syscall: %s)", path, ev.Syscall),
				}
			}
		}
	}

	return Verdict{}
}

// --- Rule 2: Anomalous Network Egress (EXFIL-002) ---

// suspiciousDomainSuffixes are known webhook/tunnel sinks.
var suspiciousDomainSuffixes = []string{
	"requestbin.com",
	"ngrok.io",
	"ngrok-free.app",
	"pipedream.net",
	"hookbin.com",
	"webhook.site",
	"burpcollaborator.net",
	"interact.sh",
	"canarytokens.com",
}

func (e *Engine) ruleAnomalousNetworkEgress(ev TelemetryEvent) Verdict {
	syscall := strings.ToLower(ev.Syscall)

	// Check raw socket creation
	if (syscall == "socket" || syscall == "connect") && strings.ToUpper(ev.SockType) == "SOCK_RAW" {
		return Verdict{
			Blocked: true,
			Rule:    "EXFIL-002",
			Reason:  "raw socket creation detected (SOCK_RAW)",
		}
	}

	// Check outbound connect to non-registry IPs
	if syscall == "connect" && ev.RemoteAddr != "" {
		ip := net.ParseIP(ev.RemoteAddr)
		if ip != nil && !e.AllowedRegistryIPs[ev.RemoteAddr] {
			// Allow loopback
			if !ip.IsLoopback() {
				return Verdict{
					Blocked: true,
					Rule:    "EXFIL-002",
					Reason:  fmt.Sprintf("outbound connection to non-registry IP: %s:%d", ev.RemoteAddr, ev.RemotePort),
				}
			}
		}
	}

	// Check DNS resolution to suspicious domains (sendto on port 53)
	if syscall == "sendto" && ev.RemotePort == 53 && ev.Path != "" {
		domain := strings.ToLower(ev.Path)
		for _, suffix := range suspiciousDomainSuffixes {
			if strings.HasSuffix(domain, suffix) {
				return Verdict{
					Blocked: true,
					Rule:    "EXFIL-002",
					Reason:  fmt.Sprintf("DNS query to suspicious domain: %s", domain),
				}
			}
		}
		// Flag dynamically generated domains (excessive length or entropy)
		if isDynamicDomain(domain) {
			return Verdict{
				Blocked: true,
				Rule:    "EXFIL-002",
				Reason:  fmt.Sprintf("DNS query to suspected dynamically generated domain: %s", domain),
			}
		}
	}

	return Verdict{}
}

// isDynamicDomain returns true for domain labels with characteristics common
// to data exfiltration via DNS (e.g., hex-encoded subdomain labels).
func isDynamicDomain(domain string) bool {
	parts := strings.Split(domain, ".")
	if len(parts) < 2 {
		return false
	}
	// Check if any subdomain label is suspiciously long (>24 chars often
	// indicates hex/base64-encoded data tunnelling)
	for _, label := range parts[:len(parts)-2] { // exclude TLD + registered domain
		if len(label) > 24 {
			return true
		}
	}
	return false
}

// --- Rule 3: Exfiltration via Execution (EXFIL-003) ---

// exfilBinaries are standard exfiltration tools.
var exfilBinaries = map[string]bool{
	"curl":   true,
	"wget":   true,
	"netcat": true,
	"nc":     true,
	"ncat":   true,
	"socat":  true,
}

func (e *Engine) ruleExfiltrationViaExecution(ev TelemetryEvent) Verdict {
	if strings.ToLower(ev.Syscall) != "execve" {
		return Verdict{}
	}

	exec := ev.Exec
	if exec == "" {
		return Verdict{}
	}

	// Extract the basename from the executable path
	parts := strings.Split(exec, "/")
	basename := parts[len(parts)-1]

	// Check known exfiltration binaries
	if exfilBinaries[strings.ToLower(basename)] {
		return Verdict{
			Blocked: true,
			Rule:    "EXFIL-003",
			Reason:  fmt.Sprintf("exfiltration binary executed: %s", exec),
		}
	}

	// Check obfuscated execution: base64 decode piped to shell
	argsJoined := strings.Join(ev.Args, " ")
	if isObfuscatedExecution(basename, argsJoined) {
		return Verdict{
			Blocked: true,
			Rule:    "EXFIL-003",
			Reason:  fmt.Sprintf("obfuscated execution detected: %s %s", exec, argsJoined),
		}
	}

	return Verdict{}
}

// isObfuscatedExecution detects patterns like: base64 -d | sh, or
// echo <data> | base64 -d | bash.
func isObfuscatedExecution(binary, args string) bool {
	lower := strings.ToLower(binary + " " + args)
	// Pattern: base64 decode piped to a shell
	if strings.Contains(lower, "base64") && (strings.Contains(lower, "| sh") ||
		strings.Contains(lower, "| bash") ||
		strings.Contains(lower, "|sh") ||
		strings.Contains(lower, "|bash")) {
		return true
	}
	// Pattern: eval with encoded content
	if strings.Contains(lower, "eval") && strings.Contains(lower, "base64") {
		return true
	}
	return false
}

// --- Rule 4: Environment Variable Harvesting (EXFIL-004) ---

// sensitiveEnvVars are environment variable names commonly targeted for
// credential exfiltration.
var sensitiveEnvVars = map[string]bool{
	"AWS_ACCESS_KEY_ID":     true,
	"AWS_SECRET_ACCESS_KEY": true,
	"AWS_SESSION_TOKEN":     true,
	"GITHUB_TOKEN":          true,
	"GH_TOKEN":              true,
	"GITLAB_TOKEN":          true,
	"NPM_TOKEN":             true,
	"DOCKER_AUTH_CONFIG":    true,
	"KUBECONFIG":            true,
	"DATABASE_URL":          true,
	"REDIS_URL":             true,
	"SECRET_KEY":            true,
	"PRIVATE_KEY":           true,
	"API_KEY":               true,
	"CI_JOB_TOKEN":          true,
}

func (e *Engine) ruleEnvVarHarvesting(ev TelemetryEvent) Verdict {
	// Direct env var read via the telemetry event
	if ev.EnvKey != "" {
		key := strings.ToUpper(ev.EnvKey)
		if sensitiveEnvVars[key] {
			return Verdict{
				Blocked: true,
				Rule:    "EXFIL-004",
				Reason:  fmt.Sprintf("sensitive environment variable access: %s", ev.EnvKey),
			}
		}
	}

	// Detect /proc/*/environ reads (bulk env harvesting)
	if ev.Path != "" && strings.Contains(ev.Path, "/proc/") && strings.HasSuffix(ev.Path, "/environ") {
		return Verdict{
			Blocked: true,
			Rule:    "EXFIL-004",
			Reason:  fmt.Sprintf("process environment enumeration via: %s", ev.Path),
		}
	}

	return Verdict{}
}
