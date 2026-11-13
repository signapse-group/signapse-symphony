# Grouped profile dashboard

The grouped service exposes the dashboard at `/` and `/profiles/:profile_id`. The tab links work with Tab and Enter. Live navigation updates the URL and leaves any submitted action attached to its original profile. **Update workflow** activates a staged local instructions revision for that profile. The form expects the revision identifier prepared by the operator.

The grouped HTTP listener binds to `127.0.0.1:4000` by default. Start its child as `{SymphonyElixir.HttpServer, mode: :profiles}`. The listener uses the CLI port override when supplied and leaves TLS termination to Tailscale Serve. Configure the Phoenix endpoint's canonical `url` with the public host, scheme `https` and port 443. Set `check_origin` to the exact public HTTPS origin and supply a stable, operator-managed `secret_key_base` through release config. The test placeholder key is replaced with a random key at startup. Grouped HTTPS deployments mark any endpoint session cookie Secure. The proxy must forward `/live/websocket` upgrades to the same listener. Serve only to the approved operators because dashboard controls use the deployment's Tailscale access policy.

| Request | Grouped behavior |
| --- | --- |
| `GET /api/v1/state` | Returns `mode: "profiles"`, aggregate `health` and a `profiles` array in catalog order. |
| `GET /api/v1/profiles/:profile_id/state` | Returns the selected profile summary, worker counts and queue details. |
| `GET /api/v1/profiles/:profile_id/issues/:issue_identifier` | Returns details for a tracked issue in that profile. |
| `POST /api/v1/profiles/:profile_id/refresh` | Queues refresh only in the selected profile. |

A profile summary has `profile_id`, `health` (`healthy` or `unavailable`), `reason`, `workflow_revision`, `instructions_revision`, `max_concurrent_agents`, and `runtime_control`. The control projection includes `enabled`, `mode`, `desired_state`, `database_error` and the heartbeat status for that profile. A healthy profile may be paused, draining or checking quota. The aggregate is `healthy` when all profiles are operational, `partial` when some are unavailable, and `unavailable` when none are operational. An unavailable but configured profile returns HTTP 200 with its reason. Invalid IDs return 404. Grouped issue lookup and refresh require the profile in the URL.

A rollout check should require `health: "healthy"`, the five expected profile IDs, their expected caps, nonempty revisions, independent runtime control memberships and healthy control databases. Verify public HTTPS and LiveView WebSocket through the proxy after startup and after restarting the grouped service. The existing positional workflow mode retains its unscoped dashboard and API.
