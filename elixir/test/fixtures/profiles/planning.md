---
tracker:
  kind: jira
  provider:
    base_url: $JIRA_BASE_URL
    email: $JIRA_EMAIL
    api_token: $JIRA_API_TOKEN
    project_key: SIGN
    issue_types: [Story]
  required_labels: []
  dispatch_states: [Planned]
  active_states: [Planned]
  terminal_states: [Done]
runtime_control:
  enabled: true
  id: planning
  members: [planning]
  path: $CONTROL_DB
workspace:
  root: $SYMPHONY_WORKSPACE_ROOT
agent:
  max_concurrent_agents: 1
---
planning fixture: {{ issue.identifier }}
