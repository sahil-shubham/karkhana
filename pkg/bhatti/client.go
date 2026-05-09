// Typed Go client for bhatti's HTTP API. Ported from
// `Karkhana.Bhatti.Client` (Elixir). The method-name vocabulary
// (Suspend / Resume / Terminate / Checkpoint) follows the v0.5
// plan; some current URL paths still use the older verbs and
// will rename on the bhatti side.
//
// Client is safe for concurrent use.
package bhatti

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"time"
)

const (
	defaultTimeout = 60 * time.Second
)

// Client wraps an HTTP client + auth.
type Client struct {
	BaseURL string
	APIKey  string
	HTTP    *http.Client
}

// New constructs a client. BaseURL like "https://bhatti.sh".
// APIKey is the per-user bearer token.
func New(baseURL, apiKey string) *Client {
	return &Client{
		BaseURL: baseURL,
		APIKey:  apiKey,
		HTTP:    &http.Client{Timeout: defaultTimeout},
	}
}

// CreateSandbox creates a sandbox from a spec. Blocks until the
// VM is running (bhatti's POST /sandboxes does this server-side).
func (c *Client) CreateSandbox(ctx context.Context, spec SandboxSpec) (*Sandbox, error) {
	var sb Sandbox
	if err := c.post(ctx, "/sandboxes", spec, &sb); err != nil {
		return nil, err
	}
	return &sb, nil
}

// ListSandboxes returns all sandboxes the API key has access to.
func (c *Client) ListSandboxes(ctx context.Context) ([]Sandbox, error) {
	var sbs []Sandbox
	if err := c.get(ctx, "/sandboxes", &sbs); err != nil {
		return nil, err
	}
	return sbs, nil
}

// GetSandbox fetches a single sandbox by ID or name.
func (c *Client) GetSandbox(ctx context.Context, idOrName string) (*Sandbox, error) {
	var sb Sandbox
	if err := c.get(ctx, "/sandboxes/"+idOrName, &sb); err != nil {
		return nil, err
	}
	return &sb, nil
}

// TerminateSandbox destroys a sandbox. Final state.
func (c *Client) TerminateSandbox(ctx context.Context, id string) error {
	return c.delete(ctx, "/sandboxes/"+id)
}

// SuspendSandbox pauses a (named) sandbox, freeing host resources.
// Hits POST /sandboxes/:id/stop until bhatti renames.
func (c *Client) SuspendSandbox(ctx context.Context, id string) error {
	return c.post(ctx, "/sandboxes/"+id+"/stop", struct{}{}, nil)
}

// ResumeSandbox resumes a suspended sandbox from snapshot.
// Hits POST /sandboxes/:id/start until bhatti renames.
func (c *Client) ResumeSandbox(ctx context.Context, id string) error {
	return c.post(ctx, "/sandboxes/"+id+"/start", struct{}{}, nil)
}

// Checkpoint takes a snapshot (memory or filesystem) of a running
// sandbox. The snapshot is independent of the source's lifecycle
// and can be restored into new sandboxes via RestoreSnapshot.
func (c *Client) Checkpoint(ctx context.Context, sandboxID string, spec CheckpointSpec) (*Snapshot, error) {
	if spec.Type == "" {
		spec.Type = "memory"
	}
	var snap Snapshot
	if err := c.post(ctx, "/sandboxes/"+sandboxID+"/checkpoint", spec, &snap); err != nil {
		return nil, err
	}
	return &snap, nil
}

// RestoreSnapshot is the v0.5 multi-restore primitive. Materializes
// N sandboxes from one snapshot in a single call. Until bhatti
// ships the batch endpoint, callers can fall back to N parallel
// CreateSandbox calls with snapshot_id in the spec.
func (c *Client) RestoreSnapshot(ctx context.Context, snapshotID string, restores []RestoreSpec) ([]Sandbox, error) {
	body := struct {
		Restores []RestoreSpec `json:"restores"`
	}{Restores: restores}
	var resp struct {
		Sandboxes []Sandbox `json:"sandboxes"`
		Failures  []any     `json:"failures"`
	}
	if err := c.post(ctx, "/snapshots/"+snapshotID+"/restore", body, &resp); err != nil {
		return nil, err
	}
	return resp.Sandboxes, nil
}

// Publish exposes a sandbox port via the bhatti public proxy.
// Returns a URL the operator (and the canvas) can hit. KasmVNC
// for the computer tier is on port 6080.
func (c *Client) Publish(ctx context.Context, sandboxID string, port int, alias string) (*PublishResult, error) {
	body := struct {
		Port  int    `json:"port"`
		Alias string `json:"alias,omitempty"`
	}{Port: port, Alias: alias}
	var pr PublishResult
	if err := c.post(ctx, "/sandboxes/"+sandboxID+"/publish", body, &pr); err != nil {
		return nil, err
	}
	return &pr, nil
}

// ListPorts returns published-port rules for a sandbox. Useful
// when the publish response shape varies across bhatti versions.
func (c *Client) ListPorts(ctx context.Context, sandboxID string) ([]PortRule, error) {
	var pr []PortRule
	if err := c.get(ctx, "/sandboxes/"+sandboxID+"/ports", &pr); err != nil {
		return nil, err
	}
	return pr, nil
}

// ListSessions returns active tracked sessions inside a sandbox
// (used today by Karkhana.AgentRPC to find pi-rpc sessions; with
// the v0.5 agent endpoint, this becomes unnecessary).
func (c *Client) ListSessions(ctx context.Context, sandboxID string) ([]SessionInfo, error) {
	var ss []SessionInfo
	if err := c.get(ctx, "/sandboxes/"+sandboxID+"/sessions", &ss); err != nil {
		return nil, err
	}
	return ss, nil
}

// Exec runs a command. For piped sessions used as agent transports,
// pass Session=true and read SessionID from the response (or attach
// via the WebSocket route).
func (c *Client) Exec(ctx context.Context, sandboxID string, req ExecRequest) (*ExecResult, error) {
	if req.TimeoutSec == 0 {
		req.TimeoutSec = 3600
	}
	// Inflate HTTP timeout to exceed the command timeout
	httpTimeout := time.Duration(req.TimeoutSec)*time.Second + 10*time.Second
	httpClient := &http.Client{Timeout: httpTimeout}

	body, _ := json.Marshal(req)
	url := c.BaseURL + "/sandboxes/" + sandboxID + "/exec"
	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	c.setHeaders(httpReq, "application/json")

	resp, err := httpClient.Do(httpReq)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	respBody, _ := io.ReadAll(resp.Body)
	if resp.StatusCode >= 400 {
		return nil, fmt.Errorf("bhatti exec %d: %s", resp.StatusCode, string(respBody))
	}
	var er ExecResult
	if err := json.Unmarshal(respBody, &er); err != nil {
		return nil, fmt.Errorf("decode exec result: %w", err)
	}
	return &er, nil
}

// ReadFile reads a file from inside the sandbox.
func (c *Client) ReadFile(ctx context.Context, sandboxID, path string) ([]byte, error) {
	q := url.Values{"path": []string{path}}
	u := c.BaseURL + "/sandboxes/" + sandboxID + "/files?" + q.Encode()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return nil, err
	}
	c.setHeaders(req, "")
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != 200 {
		return nil, fmt.Errorf("bhatti read_file %d: %s", resp.StatusCode, string(body))
	}
	return body, nil
}

// WriteFile writes bytes to a path inside the sandbox.
func (c *Client) WriteFile(ctx context.Context, sandboxID, path string, content []byte) error {
	q := url.Values{"path": []string{path}}
	u := c.BaseURL + "/sandboxes/" + sandboxID + "/files?" + q.Encode()
	req, err := http.NewRequestWithContext(ctx, http.MethodPut, u, bytes.NewReader(content))
	if err != nil {
		return err
	}
	c.setHeaders(req, "application/octet-stream")
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		body, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("bhatti write_file %d: %s", resp.StatusCode, string(body))
	}
	return nil
}

// --- private helpers ---

func (c *Client) setHeaders(r *http.Request, contentType string) {
	r.Header.Set("Authorization", "Bearer "+c.APIKey)
	if contentType != "" {
		r.Header.Set("Content-Type", contentType)
	}
}

func (c *Client) get(ctx context.Context, path string, out any) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.BaseURL+path, nil)
	if err != nil {
		return err
	}
	c.setHeaders(req, "")
	return c.do(req, out)
}

func (c *Client) post(ctx context.Context, path string, body any, out any) error {
	var rdr io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return err
		}
		rdr = bytes.NewReader(b)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.BaseURL+path, rdr)
	if err != nil {
		return err
	}
	c.setHeaders(req, "application/json")
	return c.do(req, out)
}

func (c *Client) delete(ctx context.Context, path string) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodDelete, c.BaseURL+path, nil)
	if err != nil {
		return err
	}
	c.setHeaders(req, "")
	return c.do(req, nil)
}

func (c *Client) do(req *http.Request, out any) error {
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode >= 400 {
		return fmt.Errorf("bhatti %s %s: %d %s",
			req.Method, req.URL.Path, resp.StatusCode, string(body))
	}
	if out != nil && len(body) > 0 {
		if err := json.Unmarshal(body, out); err != nil {
			return fmt.Errorf("decode %s: %w; body=%s", req.URL.Path, err, string(body))
		}
	}
	return nil
}
