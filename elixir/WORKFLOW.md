---
project:
  name: bhatti.sh
  language: astro
  build: "cd /workspace && yarn build"
  repo: github.com/sahil-shubham/bhatti.sh

tracker:
  kind: linear
  api_key: $LINEAR_BOT_API_KEY
  project_slug: fc0005a5b6e6
  assignee: me

bhatti:
  url: https://api.bhatti.sh
  api_key: $BHATTI_API_KEY
  image: karkhana-pi-v4
  cpus: 2
  memory_mb: 2048
  disk_mb: 4096

agent:
  max_concurrent_agents: 3
  max_turns: 10

claude:
  command: pi
  provider: openrouter
  model: anthropic/claude-opus-4-6
  dangerously_skip_permissions: true
  turn_timeout_ms: 3600000
  stall_timeout_ms: 300000

polling:
  interval_ms: 30000

hooks:
  timeout_ms: 180000
  after_create: |
    git config --global credential.helper '!f() { echo "username=x-access-token"; echo "password=$GH_TOKEN"; }; f'
    git config --global user.name "karkhana[bot]"
    git config --global user.email "karkhana@users.noreply.github.com"
    sudo corepack enable
    cd /workspace
    git clone https://github.com/sahil-shubham/bhatti.sh.git .
    yarn install
  before_run: |
    cd /workspace && git pull --ff-only origin main

observability:
  dashboard_enabled: false

server:
  port: 4000

lifecycle:
  auto_sync: true
  states:
    Backlog:       { type: idle, linear_type: backlog, color: "#bec2c8" }
    Todo:          { type: dispatch, linear_type: unstarted, mode: planning, on_complete: Plan Review, color: "#e2e2e2" }
    In Review:     { type: human_gate, linear_type: started, sandbox: stop, color: "#0f783c", description: "Awaiting human review" }
    Done:          { type: terminal, linear_type: completed, sandbox: destroy, color: "#5e6ad2" }
    Canceled:      { type: terminal, linear_type: canceled, sandbox: destroy, color: "#95a2b3" }
    Planning:      { type: dispatch, linear_type: started, mode: planning, on_complete: Plan Review, color: "#f2c94c", description: "Agent is producing a plan" }
    Plan Review:   { type: dispatch, linear_type: started, mode: plan_review, on_complete: Implementing, on_reject: Planning, color: "#f2994a", description: "Reviewing the plan" }
    Implementing:  { type: dispatch, linear_type: started, mode: implementation, on_complete: In Review, color: "#4ea7fc", description: "Agent is implementing" }

modes:
  planning:
    prompt: modes/planning.md
    gates:
      - name: plan-document
        check: document_exists
        title: plan
        on_failure: retry_with_feedback
        message: "Create a Linear document titled 'Plan: {{ issue.identifier }}' on this issue with the plan content using the documentCreate GraphQL mutation."

  plan_review:
    prompt: modes/review.md
    gates:
      - name: review-decision
        check: document_exists
        title: "review:"
        on_failure: retry_with_feedback
        message: "You must create a Linear document on the issue titled either 'Review: Approved' or 'Review: Rejected' with your assessment. Use curl to call the Linear API as shown in your instructions."

  implementation:
    prompt: modes/implementation.md
    gates:
      - name: builds
        check: command
        command: "cd /workspace && yarn build"
        on_failure: retry_with_feedback
      - name: branch-pushed
        check: command
        command: "cd /workspace && git log --oneline -1 origin/$(git branch --show-current) 2>/dev/null"
        on_failure: retry_with_feedback
        message: "Push the branch before completing"
---

You are a distinguished systems engineer working on the bhatti.sh website (Astro/Starlight).
