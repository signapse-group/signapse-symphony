---
tracker:
  kind: jira
  provider:
    base_url: $JIRA_BASE_URL
    email: $JIRA_EMAIL
    api_token: $JIRA_API_TOKEN
    project_key: SIGN
    issue_types: [Subtask]
    routing_labels: [route-frontend, route-backend, route-quality-assurance, route-landing, route-mdg]
  required_labels: [route-landing]
  dispatch_states: [Ready, Progress, In Review]
  active_states: [Ready, Progress, In Review]
  terminal_states: [Done]
runtime_control:
  enabled: true
  id: landing
  members: [landing]
  path: $CONTROL_DB
workspace:
  root: $SYMPHONY_WORKSPACE_ROOT
agent:
  max_concurrent_agents: 1
---
landing fixture: {{ issue.identifier }}
