# Kiểm chứng CI/CD và gate sau merge PR #5

Ngày 2026-10-16 (UTC+7). Commit merge: `7f93b80218d9f12f7bce1749f3d2cf07b3d706d1`.

**Kết luận: CI/build/CD và health production đạt; nghiệm thu đầy đủ theo plan chưa đạt.** Blocker containment đã được tái hiện trên máy local lẫn server, gồm transport SSH thật. Bản mới đã được CD tự động triển khai tới cả bốn service dù blocker này còn mở.

Đây là lượt kiểm tra và thử nghiệm cô lập. Không sửa runtime source, không tự pause/resume, restart, rollback service, thay workflow production hoặc ghi tracker. Việc đổi binary/restart production trong khoảng kiểm tra do workflow CD đã có thực hiện tự động sau merge.

## Chuỗi bằng chứng GitHub

| Mốc | Kết quả và bằng chứng |
| --- | --- |
| Merge | [PR #5](https://github.com/signapse-group/signapse-symphony/pull/5) merge lúc 15:35:52, commit `7f93b80`. |
| PR checks | `make-all` xanh. Lỗi placeholder trong mô tả PR đã sửa; [lint chạy lại](https://github.com/signapse-group/signapse-symphony/actions/runs/38874571695) xanh trước merge. Run lỗi cũ vẫn còn trong lịch sử, không phải lỗi mới. |
| Main CI | [make-all 38874756441](https://github.com/signapse-group/signapse-symphony/actions/runs/38874756441) xanh: 375 tests, 0 lỗi, 9 skips; Dialyzer 0 lỗi; 9 Python tests đạt. |
| Build/release | [burrito-nightly 38874756457](https://github.com/signapse-group/signapse-symphony/actions/runs/38874756457) xanh: build và smoke Linux x86_64/arm64, macOS x86_64/arm64, publish nightly. |
| Deploy đầu | [38874874660](https://github.com/signapse-group/signapse-symphony/actions/runs/38874874660) success nhưng bỏ qua triển khai vì Burrito chưa hoàn tất. Đây là behavior chờ đủ hai workflow, không phải bằng chứng đã deploy. |
| Deploy thực tế | [38875303790](https://github.com/signapse-group/signapse-symphony/actions/runs/38875303790) xanh: gate SHA/CI/build, download artifact đúng run, Tailscale, checksum, SSH và bước deploy đều thực thi. |
| Server xác nhận | Journal `symphony-cd-38875303790-1.service` ghi hoàn tất lúc 15:41:41: cả bốn service healthy. |

Smoke đa nền tảng hiện chỉ chạy executable không đối số, xác nhận exit code 1 và chuỗi cảnh báo engineering preview. Nó không chạy agent, boundary hoặc teardown. Vì vậy build/smoke macOS xanh không đóng gate boundary macOS.

## Local và server

Local checkout còn ở branch `codex/phase-boundary-handoff`, HEAD `0b77bb7`; đã fetch `origin/main` tới `7f93b80`. So sánh source implementation, tests, scripts, workflows, SPEC và README giữa hai revision không có diff. Không reset checkout của người dùng.

Bản source kiểm thử được lấy từ `git archive origin/main`. Các file text CRLF do vận chuyển từ Windows được chuẩn hóa LF trong bản sao kiểm thử; không sửa source checkout. Không dùng workspace test làm source checkout cho agent thật.

| Môi trường | Kết quả |
| --- | --- |
| Local Docker trên máy Windows | Elixir 1.19.5 / OTP 28. Tests tập trung: 115 tests, 0 lỗi, 3 skips SSH. Full `mix test --cover`: 375 tests, 0 lỗi, 9 skips; coverage theo cấu hình repo 100%. `MIX_ENV=test mix lint` đạt, không có issue. |
| Local Python container | 9 deployment/CI tests đạt sau khi cài `jq` vào container tạm cho đúng prerequisites của shell gate. Lượt đầu thiếu `jq` gây 1 failure môi trường; không sửa dependency hay test để bỏ qua. |
| Local binary smoke | Artifact Linux x86_64 tải trực tiếp từ build run mới khởi động được trong Docker và cho exit/cảnh báo đúng smoke contract. Đây không phải native Windows runtime. |
| Server source cô lập | `/tmp/symphony-postmerge-7f93b80`: `make -C elixir all` đạt, 375 tests, 0 lỗi, 6 live skips, coverage 100%, format/specs/lint/Dialyzer đạt. Ba case SSH không skip: dùng sshd loopback tạm, host verification và key riêng trong fixture. |
| Server Python | 9 deployment/CI tests đạt trên đúng source merge. |

Coverage 100% là theo danh sách module được gate repo tính; các module stateful như Orchestrator, AgentRunner và AppServer đã được repo loại khỏi chỉ số này. Không dùng con số coverage để tuyên bố mọi invariant đều được kiểm chứng.

Local full tests skip 6 live tests và 3 SSH tests; server chạy 3 SSH tests nên chỉ còn 6 live skips. Không thực hiện mutation Git/Jira để bật các live tests.

## Binary, workflow và recovery production

Binary của cả bốn service trỏ tới:

`/opt/apps/symphony/runtime/releases/7f93b80218d9f12f7bce1749f3d2cf07b3d706d1/symphony`

Đã kiểm cả systemd `ExecStart` lẫn `/proc/<pid>/exe`: BEAM nằm trong `install-7f93b80…/<service>/.burrito/…`, không chỉ đổi symlink. Hash binary server khớp file tải từ artifact build run và checksum đi kèm:

`02f7a59a7321d78167ea814fd135f34fcc2321c14542fb9d8a0744b08404a6cf`

| Service | Port | PID sau deploy | Health/control quan sát được |
| --- | --- | --- | --- |
| BE | 4000 | 435265 | active/running, JSON không lỗi, heartbeat online; có worker SIGN-182. |
| FE | 4001 | 435266 | active/running, JSON không lỗi, heartbeat online, không có worker. |
| Landing | 4002 | 435267 | active/running, JSON không lỗi, heartbeat online, không có worker. |
| QA | 4003 | 435268 | active/running, JSON không lỗi, heartbeat online, không có worker. |

PID ổn định qua các lần đọc sau deploy; `NRestarts=0`, `Result=success`, `KillMode=control-group`. Đây là health tại thời điểm kiểm tra, không phải cam kết trạng thái tương lai.

Đã đọc file WORKFLOW thực được systemd truyền vào, tại `runtime/repos/<repo>/WORKFLOW.md`, thay vì lấy committed WORKFLOW của Symphony để suy ra production:

- Cả bốn khai báo dispatch/active `[Ready, Progress, In Review]`, `review_state: In Review`, `session_boundary_states: [Ready]`.
- Runtime control được bật. BE/FE/Landing dùng chung `runtime-control.sqlite3`, membership `[be, fe, landing]`. QA dùng `runtime-control-qa.sqlite3`, membership `[qa]`.
- Hai database được mở chỉ đọc và `PRAGMA quick_check` đều trả `ok`. Ledger BE có recovery record cho SIGN-182, workspace đúng `/opt/apps/symphony/workspaces-jira/SIGN-182`; QA không có pending retry tại thời điểm kiểm.
- Các control vẫn `running`, version BE/FE/Landing 15, QA 14, không lỗi database. Không có thao tác resume nào do lượt kiểm tra này thực hiện.
- SIGN-182 có thread mới sau CD restart và một process Codex đang chạy trong workspace tương ứng. Đây là phục hồi sau deploy thông thường, không phải bằng chứng chuyển phase/canary. Không quan sát được handoff boundary live đủ để nghiệm thu.
- Backup rollback tồn tại trong `runtime/deployments/38875303790-1/backup/`: `before.json` và bốn drop-in `.conf`. Không kích hoạt rollback production để thử nghiệm.

## Đối chiếu các gate còn mở

| Gate | Trạng thái | Bằng chứng/giới hạn |
| --- | --- | --- |
| Interrupt giữa turn, ba hướng chuyển phase | Đạt trong regression local Linux/server | Fake Codex chưa gửi `turn/completed`; stop, worker DOWN, fresh thread/full prompt, admission và output preservation được kiểm. SSH thật chạy trên server. |
| Message cũ và ownership khi stop chưa rõ | Đạt trong tests hiện có | Message worker cũ bị bỏ; claim/slot và marker giữ lại khi thiếu thông tin session. Không diễn giải thành mọi race production đã được thử. |
| Restart/recovery, pause/drain, permit | Đạt trong phạm vi tests | Tests recovery/control/core xanh; marker handoff, pause khi restore và giữ output terminal qua startup cleanup được kiểm. Production control/membership phù hợp prerequisites. Chưa diễn tập kill/restart tại mọi khoảng handoff trên production. |
| Tool con cùng group | Đạt trong fixture | Process con bị dừng trước thread thay thế; local và SSH. |
| Tool khác group nhưng vẫn còn trong ancestry | Đạt trong fixture | Stop báo chưa xác nhận; không coi port closure là hoàn tất. |
| Tool daemonize/reparent hoàn toàn | **FAIL, blocker xác nhận** | Probe trên source merge chứng minh `stop_session` trả `:ok` dù process con vẫn sống, PPID 1, group riêng; tái hiện trên local Docker, server local và server SSH. |
| Boundary macOS | Chưa kiểm chứng | Không có host macOS để chạy; implementation dùng `setsid` và công cụ Linux. Build/smoke CLI không đủ đóng gate này. |
| Native Windows | Chưa kiểm chứng/không có bằng chứng hỗ trợ | Local thực thi bằng Linux Docker, không tuyên bố runtime native Windows đạt. |
| QA canary ba phase | Chưa thực hiện | Không có QA Subtask canary được coordinator giao trong yêu cầu này; không reset SIGN-164, không chuyển tracker để tạo bằng chứng. |
| Review phản biện độc lập | Chưa có bằng chứng mới | CI/tests không thay thế maintainer review hoặc chứng minh đã đóng mọi finding. |
| Rollout tuần tự riêng QA theo plan | **Không được CD thực thi** | Pipeline hiện deploy cả bốn service sau CI/build, không pause/drain QA hoặc chờ canary/gate trong plan. BE đang chạy công việc đã bị restart bởi CD. |

### Probe containment tái hiện lỗi

Probe tạo fake app-server và tool `sleep 300` trong thư mục tạm. Tool được khởi chạy bằng session riêng; process khởi tạo thoát trước khi kiểm, khiến tool được reparent về PID 1. Sau đó gọi `AppServer.stop_session` thật trên source merge và kiểm `ps` trước/sau.

| Nơi chạy | Group phiên | PID/group tool | PPID | Kết quả stop | Tool sau stop |
| --- | --- | --- | --- | --- | --- |
| Local Docker | 175 | 177 | 1 | `:ok` | Vẫn `Ss` |
| Server local | 433669 | 433671 | 1 | `:ok` | Vẫn `Ss` |
| Server SSH loopback | 438917 | 438919 | 1 | `:ok` | Vẫn `Ss` |

Probe có assertion xác nhận lỗi tồn tại, nên kết quả `1 test, 0 failures` của probe nghĩa là tái hiện đúng bug, **không phải containment đạt**. Tool thử nghiệm được kill và dọn sau mỗi probe. Không dùng tool production để thử.

Nguyên nhân: teardown chỉ có process group và snapshot quan hệ cha/con hiện tại. Khi tool đã đổi group và mất ancestry, không còn bằng chứng liên kết với phiên. Cần containment bền vững cho toàn bộ tool của phiên, hoặc cơ chế chặn handoff khi không thể chứng minh ownership; chỉ thêm polling, đóng SSH hoặc lặp `kill` theo group không giải quyết được trường hợp này.

## Kết luận vận hành và bằng chứng lưu

Main đã merge, build/release và deploy thành công lúc 15:41 UTC+7. Pipeline vận hành đúng gate kỹ thuật đã cấu hình; gate nghiệm thu trong plan không được tự động cưỡng chế. Vì containment đã fail và QA canary chưa có, không tuyên bố phase-boundary đã được nghiệm thu đầy đủ chỉ dựa trên CI/health xanh. Bước tiếp theo cần giải quyết blocker containment và thống nhất gate rollout trước đợt thay runtime tiếp theo.

Bằng chứng local nằm trong thư mục tạm `symphony-postmerge-7f93b80`: `local-gates.log`, `local-full-test.log`, `local-lint.log`, `local-containment-probe.log`; probe source là `elixir/containment_probe.exs`. Artifact riêng tại `symphony-postmerge-artifact-7f93b80`.

Bằng chứng server tại `/tmp/symphony-postmerge-7f93b80`: `postmerge-make-all.log`, `containment-probe.log`, `containment-probe-ssh.log`, `server-state-final.txt`, `elixir/containment_probe.exs`. Không đưa private key, credential hoặc environment production vào repo. Báo cáo này lưu local để review, chưa commit/push và không tạo PR mới.
