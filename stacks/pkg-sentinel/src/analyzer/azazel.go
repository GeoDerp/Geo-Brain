// Package analyzer manages the Azazel eBPF tracer lifecycle and parses its
// NDJSON telemetry stream in real-time. It bridges the tracing engine with the
// rules-based exfiltration detection engine and provides an optional webhook
// out to a local LLM inference endpoint for deeper behavioral analysis.
package analyzer

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os/exec"
	"time"

	"github.com/stig-homelab/pkg-sentinel/rules"
)

// Result captures the outcome of an Azazel detonation analysis session.
type Result struct {
	Safe       bool             `json:"safe"`
	Violations []rules.Verdict  `json:"violations,omitempty"`
	EventCount int              `json:"event_count"`
	Duration   time.Duration    `json:"duration"`
	LLMVerdict *LLMAnalysis     `json:"llm_verdict,omitempty"`
}

// LLMAnalysis holds the response from the local AI inference endpoint.
type LLMAnalysis struct {
	Suspicious bool   `json:"suspicious"`
	Confidence float64 `json:"confidence"`
	Summary    string `json:"summary"`
}

// Analyzer manages Azazel eBPF tracing sessions.
type Analyzer struct {
	AzazelBin   string
	RuleEngine  *rules.Engine
	LLMEndpoint string // optional; empty string disables LLM analysis
	LLMModel    string // model name for the LLM endpoint
}

// New creates a new Analyzer with the given Azazel binary path, rule engine,
// optional LLM endpoint, and model name.
func New(azazelBin string, engine *rules.Engine, llmEndpoint, llmModel string) *Analyzer {
	return &Analyzer{
		AzazelBin:   azazelBin,
		RuleEngine:  engine,
		LLMEndpoint: llmEndpoint,
		LLMModel:    llmModel,
	}
}

// Trace attaches Azazel to the specified container PID / cgroup and streams
// telemetry through the rule engine. It blocks until the context is cancelled
// or the Azazel process exits.
func (a *Analyzer) Trace(ctx context.Context, containerPID int, cgroupPath string) (*Result, error) {
	start := time.Now()

	args := []string{
		"--pid", fmt.Sprintf("%d", containerPID),
		"--cgroup", cgroupPath,
		"--format", "ndjson",
	}

	cmd := exec.CommandContext(ctx, a.AzazelBin, args...)

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, fmt.Errorf("azazel stdout pipe: %w", err)
	}

	var stderrBuf bytes.Buffer
	cmd.Stderr = &stderrBuf

	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("azazel start: %w", err)
	}

	result := &Result{Safe: true}
	var allEvents []rules.TelemetryEvent

	// Stream NDJSON and evaluate each event in real-time
	scanner := bufio.NewScanner(stdout)
	// Allow up to 1MB per line for large telemetry events
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)

	for scanner.Scan() {
		var ev rules.TelemetryEvent
		if err := json.Unmarshal(scanner.Bytes(), &ev); err != nil {
			log.Printf("[analyzer] skipping malformed event: %v", err)
			continue
		}

		result.EventCount++
		allEvents = append(allEvents, ev)

		verdict := a.RuleEngine.Evaluate(ev)
		if verdict.Blocked {
			result.Safe = false
			result.Violations = append(result.Violations, verdict)
			log.Printf("[analyzer] VIOLATION %s: %s (pid=%d)", verdict.Rule, verdict.Reason, ev.PID)
		}
	}

	if err := scanner.Err(); err != nil && ctx.Err() == nil {
		log.Printf("[analyzer] scanner error: %v", err)
	}

	// Wait for Azazel to exit (may already be done if context cancelled)
	_ = cmd.Wait()

	result.Duration = time.Since(start)

	// If the rule engine passed but an LLM endpoint is configured, perform
	// deeper behavioral analysis on the full event stream.
	if result.Safe && a.LLMEndpoint != "" && len(allEvents) > 0 {
		llmResult, err := a.queryLLM(ctx, allEvents)
		if err != nil {
			log.Printf("[analyzer] LLM analysis failed (non-blocking): %v", err)
		} else {
			result.LLMVerdict = llmResult
			if llmResult.Suspicious {
				result.Safe = false
				result.Violations = append(result.Violations, rules.Verdict{
					Blocked: true,
					Rule:    "LLM-001",
					Reason:  fmt.Sprintf("LLM flagged suspicious behavior (confidence: %.2f): %s", llmResult.Confidence, llmResult.Summary),
				})
			}
		}
	}

	return result, nil
}

// llmRequest is the payload sent to the local AI inference endpoint.
type llmRequest struct {
	Model    string       `json:"model"`
	Messages []llmMessage `json:"messages"`
}

type llmMessage struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

// queryLLM sends the collected telemetry events to the local LLM endpoint
// for behavioral analysis. The LLM is expected to return a JSON object
// matching LLMAnalysis.
func (a *Analyzer) queryLLM(ctx context.Context, events []rules.TelemetryEvent) (*LLMAnalysis, error) {
	if a.LLMEndpoint == "" {
		return nil, nil
	}

	// Serialize events for the prompt (limit to last 100 events to keep
	// the context window manageable)
	maxEvents := 100
	if len(events) > maxEvents {
		events = events[len(events)-maxEvents:]
	}
	eventsJSON, err := json.Marshal(events)
	if err != nil {
		return nil, fmt.Errorf("marshal events: %w", err)
	}

	prompt := fmt.Sprintf(
		"Analyze the following eBPF syscall telemetry from a package installation sandbox. "+
			"Determine if the behavior is suspicious or indicates data exfiltration. "+
			"Respond ONLY with a JSON object: {\"suspicious\": bool, \"confidence\": float, \"summary\": string}.\n\n"+
			"Telemetry:\n%s", string(eventsJSON),
	)

	reqBody := llmRequest{
		Model: a.LLMModel,
		Messages: []llmMessage{
			{Role: "system", Content: "You are a cybersecurity analyst specializing in supply-chain attacks."},
			{Role: "user", Content: prompt},
		},
	}

	body, err := json.Marshal(reqBody)
	if err != nil {
		return nil, fmt.Errorf("marshal LLM request: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, a.LLMEndpoint, bytes.NewReader(body))
	if err != nil {
		return nil, fmt.Errorf("create LLM request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")

	client := &http.Client{Timeout: 30 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("LLM request: %w", err)
	}
	defer func() {
		_ = resp.Body.Close()
	}()

	if resp.StatusCode != http.StatusOK {
		respBody, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("LLM returned %d: %s", resp.StatusCode, string(respBody))
	}

	// Parse the LLM response — expect the model to return a JSON object
	// either directly or wrapped in a chat completion structure.
	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("read LLM response: %w", err)
	}

	var analysis LLMAnalysis
	if err := json.Unmarshal(respBody, &analysis); err != nil {
		// Try extracting from a chat-completion wrapper
		var wrapper struct {
			Choices []struct {
				Message struct {
					Content string `json:"content"`
				} `json:"message"`
			} `json:"choices"`
		}
		if err2 := json.Unmarshal(respBody, &wrapper); err2 == nil && len(wrapper.Choices) > 0 {
			if err3 := json.Unmarshal([]byte(wrapper.Choices[0].Message.Content), &analysis); err3 != nil {
				return nil, fmt.Errorf("parse LLM content: %w (raw: %s)", err3, wrapper.Choices[0].Message.Content)
			}
		} else {
			return nil, fmt.Errorf("parse LLM response: %w (raw: %s)", err, string(respBody))
		}
	}

	return &analysis, nil
}
