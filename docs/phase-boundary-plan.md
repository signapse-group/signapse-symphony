# Kế hoạch sửa cơ chế chuyển phiên tại ranh giới phase

Ngày: 2026-10-16 (UTC+7). Trạng thái: người dùng đã duyệt triển khai; candidate triển khai được bàn giao qua draft PR; chưa đạt gate ready.

Plan này tổng hợp đề xuất ban đầu và các quyết định đã được xác nhận trong cuộc trao đổi. Sau lượt lưu/review, người dùng đã yêu cầu triển khai theo plan, gồm source, test, docs, commit/push và draft PR. Phần rollout vẫn phải được giao riêng. Tiêu chí bên dưới là yêu cầu; chỉ phần bằng chứng triển khai mới ghi kết quả thực tế.

## Kết quả cần đạt và phạm vi

Khi một lần reconcile thành công quan sát issue vượt `tracker.review_state` hoặc `tracker.session_boundary_states`, Symphony phải dừng worker hiện tại ngay trong turn, giữ workspace/output và chỉ mở phiên tiếp theo sau khi xác nhận worker cũ cùng các tool/process thuộc phiên đã dừng. Phiên mới đọc live issue, qua các kiểm tra điều kiện chạy hiện có (admission) và nhận full prompt đúng phase trong thread mới.

Đây là cơ chế handoff dựa trên polling. Nó không ngăn được mutation giữa thời điểm tracker chuyển trạng thái và thời điểm Symphony quan sát được, không phát hiện được mọi transition đã đổi rồi quay lại giữa hai snapshot, và không được coi lỗi đọc tracker là bằng chứng vượt boundary. Người dùng chấp nhận giới hạn này. Thay đổi này không tạo gate phân quyền đồng bộ trước mọi thao tác ghi qua Git, Jira hoặc kênh khác.

Một PR Symphony bao gồm runtime, regression tests tập trung và tài liệu contract bị ảnh hưởng. Không dự kiến thêm config, dependency, phase framework, permission broker, schema cơ sở dữ liệu hoặc hệ thống CD. Mỗi repo sử dụng Symphony tiếp tục sở hữu policy phase của mình. Thay đổi workflow/quyền QA, merge, release, deployment và canary nằm ngoài phạm vi implementation này.

## Các quyết định đã chốt

| Quyết định | Hành vi đã thống nhất |
| --- | --- |
| Công việc hiện tại | Đã lưu/review plan; người dùng đã duyệt triển khai và chuẩn bị draft PR. |
| Bàn giao source ở giai đoạn tiếp theo | Implement, test, cập nhật docs, commit, push và tạo draft PR. Maintainer quyết định merge. |
| Handoff bình thường | Tự mở thread mới sau khi xác nhận stop và qua live admission; giữ workspace/output. |
| Chưa xác nhận được stop | Giữ ownership và bằng chứng recovery, chặn phiên mới, yêu cầu operator kiểm tra. Không thêm vòng tự động thử dừng lại khi kết quả stop chưa rõ. |
| Restart giữa handoff | Giữ recovery pending đến khi operator xác nhận qua cơ chế recovery hiện có; không tự chạy tiếp issue. |
| Các đường thực thi | Kiểm chứng cả worker local và SSH, gồm tool/process con thuộc phiên. Đường nào chưa có bằng chứng thì chưa đạt gate của đường đó. |
| Sửa teardown | Nếu cơ chế hiện tại không đáp ứng invariant, đưa phần sửa teardown tối thiểu cần thiết vào cùng PR. |
| Giới hạn polling | Chấp nhận trong PR này; cơ chế chặn mutation là công việc riêng. |
| Bị chặn bởi môi trường | Vẫn có thể tạo draft PR nhưng phải ghi rõ checks còn thiếu và blocker. Giữ PR ở draft, chưa đủ điều kiện merge cho đến khi mọi gate bắt buộc đạt. |

## Bằng chứng và baseline

- Đề xuất ban đầu dùng Symphony revision `850924f919270293a50efbd30c8401c833005c2b`.
- Lượt review source trong cuộc trao đổi dùng HEAD `b8d3636fd82208cb69a2da91e6116ae95fbcaa73`. Working tree sạch trước khi thêm tài liệu này. Thư mục runtime, boundary test và SPEC đã kiểm tra không có diff so với baseline của đề xuất.
- [AgentRunner](../elixir/lib/symphony_elixir/agent_runner.ex) chỉ kiểm `same_agent_task?` sau `run_turn`. Continuation prompt yêu cầu agent không kết thúc khi issue vẫn active.
- [Orchestrator](../elixir/lib/symphony_elixir/orchestrator.ex) refresh snapshot của issue đang chạy khi trạng thái vẫn active mà chưa kiểm boundary của assignment. Một chu kỳ dispatch có thể reconcile rồi dispatch lại ngay trong cùng chu kỳ.
- `terminate_running_issue` xóa retry đã lưu trước khi dừng task, sau đó xóa trạng thái running/claim. `stop_running_task` còn bỏ monitor và flush thông báo của worker; hành vi hiện tại chưa đủ chứng minh contract stop được đề xuất.
- Runtime và Codex messages được ghép theo issue ID. Hiện chúng chưa phân biệt worker cũ với worker thay thế của cùng issue.
- [AppServer](../elixir/lib/symphony_elixir/codex/app_server.ex) dừng phiên bằng cách đóng port. Đường local khởi chạy qua shell port; đường remote qua SSH. Chỉ đóng port chưa chứng minh process con đã dừng.
- [Boundary tests](../elixir/test/symphony_elixir/review_task_test.exs) hiện yêu cầu reconcile giữ worker qua Ready → Progress. [SPEC](../SPEC.md) mô tả hoàn tất turn trước khi handoff tại boundary. Cả hai cần được đổi contract có chủ đích.

Đề xuất ban đầu còn ghi nhận bằng chứng server/session từ trước về SIGN-164, SIGN-144, QA PR #14 và baseline workflow QA tại `0ac1ff77733c7f28380c94701f6003c9aaff0ac6`. Đây là đầu vào lịch sử, chưa được kiểm lại độc lập trên môi trường live trong cuộc trao đổi này. Profile QA trong repo planning và WORKFLOW của repo sử dụng Symphony vẫn là nguồn policy; không suy ra cấu hình đang deploy chỉ từ file đã commit.

## Các điều kiện bắt buộc phải giữ đúng

1. So assignment đang chạy với issue mới trước khi ghi đè snapshot cũ. Tái sử dụng predicate boundary hiện có, gồm chuẩn hóa hoa/thường, khoảng trắng và semantics xác định issue nằm trong hay ngoài từng boundary state đã cấu hình.
2. Xác nhận worker và tool/process thuộc phiên đã dừng trước khi worker khác bắt đầu thực thi. Chỉ gửi signal, thấy Elixir PID chết, port đóng, turn ID đổi hoặc kỳ vọng cleanup hook chạy đều chưa đủ.
3. Khi chưa xác nhận stop, giữ ownership, tiếp tục tính issue vào số slot đang sử dụng, bảo toàn bằng chứng recovery được lưu bền vững và chặn redispatch. Log/status phải thể hiện lỗi rõ ràng. Các lần poll sau không được âm thầm nhả claim hoặc lặp lại thao tác stop. Operator recovery dùng cơ chế điều khiển và quyền hiện có.
4. Giữ workspace, output chưa commit và bằng chứng recovery. Không reset trạng thái tracker. Handoff tại boundary là sự kiện lifecycle, không phải crash để tăng error backoff.
5. Lưu đủ trạng thái recovery bằng cơ chế hiện có trước khi nhả ownership, để restart tại bất kỳ thời điểm nào giữa stop và redispatch đều giữ issue chờ operator xác nhận. Chỉ giữ claim trong RAM không đáp ứng yêu cầu này.
6. Handoff bình thường chỉ tự chạy tiếp sau khi xác nhận stop và qua admission với status/route/dependency mới đọc. Boundary không làm trạng thái ngoài dispatch trở nên đủ điều kiện chạy.
7. Message từ worker cũ không được thay đổi session, workspace, usage hoặc recovery của worker thay thế. Nếu cần correlation, ưu tiên PID/identity worker hiện có; không tạo registry mới.
8. Mỗi phiên phase dùng `thread_id` mới và full prompt đúng phase. Turn mới hoặc `session_id` ghép thread/turn không phải bằng chứng có thread mới.
9. Continuation chỉ tiếp tục assignment hiện tại và cho phép kết thúc tại boundary đã cấu hình. Không cấp quyền của phase tiếp theo hoặc buộc handoff ở mọi thay đổi active state không được cấu hình boundary.

Nếu cơ chế recovery hiện có không biểu diễn được việc chờ operator xác nhận như đã chốt mà không mở rộng schema hoặc policy, ghi rõ gap cụ thể và giữ PR chưa đủ điều kiện ready. Không âm thầm hạ yêu cầu hoặc cấp quyền mutation của Progress cho Review.

## Danh sách vị trí cần sửa

| Vị trí | Công việc dự kiến |
| --- | --- |
| `elixir/lib/symphony_elixir/agent_runner.ex` | Expose predicate `same_agent_task?` hiện có với `@spec` liền kề; giữ kiểm sau turn; sửa continuation; gắn identity vào message worker gửi đi nếu regression chứng minh cần. |
| `elixir/lib/symphony_elixir/orchestrator.ex` | Kiểm boundary trước khi refresh active snapshot; sửa thứ tự xác nhận stop/claim/recovery; giữ admission và bỏ qua message từ worker cũ khi cần. |
| `elixir/lib/symphony_elixir/codex/app_server.ex` và code khởi chạy/teardown SSH hiện có | Khảo sát teardown trước. Chỉ sửa phần cần thiết để chứng minh process local và remote đã dừng. Bắt buộc sửa nếu cơ chế hiện tại không đáp ứng invariant. |
| `elixir/test/symphony_elixir/review_task_test.exs` | Mở rộng fixture fake Codex/tracker để giữ turn chưa hoàn tất, thay expectation reconcile cũ, kiểm thread/prompt mới và output được giữ. |
| `elixir/test/symphony_elixir/core_test.exs` | Tái sử dụng điểm kiểm thử hiện có cho ownership, dispatch, recovery và race với message đến muộn được điều khiển chủ động. |
| Tests AppServer, runtime-control và SSH hiện có | Kiểm teardown, permit, pause/drain và restart trên các đường bị ảnh hưởng; thêm case tập trung tại nơi behavior thay đổi. |
| `SPEC.md`, `elixir/README.md`, `README.md` | Đồng bộ thời điểm boundary, ownership, recovery qua operator và giới hạn polling với implementation. |
| `elixir/WORKFLOW.md` | Rà wording/reference bị ảnh hưởng; giữ profile thực thi riêng của repo này. |

Đọc mọi caller của helper định sửa, gồm các đường terminal, issue mất khỏi tracker, mất route, stalled và blocked. Sửa stop dùng chung phải giữ behavior cleanup/retry của các đường đó. Danh sách trên là điểm xuất phát, không phải giới hạn hai file để bỏ sót phần sửa cần thiết.

## Trình tự triển khai

### 1. Làm rõ teardown và khóa regression

Kiểm lại HEAD, hướng dẫn repo, runtime controls và caller của helper. Dùng fixture fake Codex/tracker hiện có trong workspace cô lập, không dùng credential tracker live hoặc agent production.

Cho fake Codex bắt đầu turn và xác nhận đã sẵn sàng nhưng chưa gửi `turn/completed`. Đổi tracker Ready → Progress rồi gọi reconcile thật. Baseline phải thất bại ở yêu cầu dừng worker. Dùng handshake, monitor và hiệu ứng quan sát được thay vì sleep dài hoặc chỉ kiểm PID tồn tại.

Kèm một tool/process con cô lập có hiệu ứng quan sát được. Kiểm nó ngừng hoạt động trên cả đường local và SSH. Kiểm tra kết nối chỉ đọc tuân theo hướng dẫn server đã được cho phép sẵn của repo. Fixture chạy qua SSH phải dùng workspace test cô lập, không thay đổi service đã deploy hoặc binary runtime dùng chung.

Làm rõ cơ chế teardown tối thiểu trước khi giả định có thể dùng lại nguyên stop helper. Nếu môi trường ngăn chạy test SSH, ghi gate đó là chưa kiểm chứng, không ghi đạt.

### 2. Thêm kiểm boundary và sửa continuation theo assignment

Dùng chung predicate trong AgentRunner và Orchestrator. Trong nhánh reconcile active state, so issue cũ của worker đang chạy với issue vừa đọc: refresh nếu vẫn cùng assignment; stop/handoff nếu vượt boundary đã cấu hình. Giữ xử lý hiện có cho issue terminal, non-active, mất khỏi tracker và mất route.

Sửa continuation để tiếp tục assignment hiện tại từ workspace/workpad đã có và cho phép kết thúc sau transition/readback tại boundary. Không render full prompt của phase tiếp theo vào thread cũ. Giữ kiểm boundary sau normal completion làm lớp dự phòng.

### 3. Hoàn tất ownership, recovery và redispatch

Tái sử dụng stop policy và timeout hiện có, tắt cleanup workspace khi handoff. Không nhả claim hoặc xóa bằng chứng recovery trước khi xác nhận stop. Nếu kết quả chưa rõ, giữ issue chờ operator kiểm tra và thể hiện nguyên nhân qua log/status hiện có.

Test restart phải bao phủ khoảng trước xác nhận stop và khoảng sau xác nhận stop nhưng trước dispatch mới. Cả hai phải giữ recovery pending chờ operator xác nhận. Handoff bình thường không bị gián đoạn sẽ tự qua live admission hiện có và mở thread mới.

Chủ động đưa runtime/Codex messages cũ đến muộn vào mailbox khi worker thay thế đã được đăng ký. Nếu thứ tự xử lý hiện có không ngăn được gán nhầm, truyền identity worker hiện có ở cả đầu gửi và nhận. Kiểm workspace, session, usage và recovery được lưu bền vững của worker thay thế không bị ảnh hưởng.

Log issue, phase trước/sau, session, lý do stop và kết quả theo [quy ước logging](../elixir/docs/logging.md). Ghi giới hạn polling trong docs; shortcut có giới hạn đã biết cần comment ngắn dạng `shortcut: <giới hạn>, <khi cần nâng cấp>`.

### 4. Kiểm chứng contract và chuẩn bị bàn giao source

Chạy focused tests trước completion gate đầy đủ. Review phản biện sớm phần stop/claim/recovery và review candidate cuối. Cập nhật tài liệu bị ảnh hưởng trong cùng PR.

Dùng PR template và checker của repo. Commit, push và tạo draft PR kèm revision, bằng chứng kiểm chứng, blocker còn lại và giới hạn polling đã chấp nhận. Draft được phép thiếu bằng chứng do môi trường, nhưng thiếu đó chặn chuyển ready và nghiệm thu để merge.

## Ma trận kiểm chứng

Tất cả các dòng dưới đây là yêu cầu, chưa phải kết quả đã đạt.

| Trường hợp | Bằng chứng cần có |
| --- | --- |
| Ready → Progress; Progress → In Review; In Review → Progress giữa turn | Reconcile dừng worker cũ trước `turn/completed`; hiệu ứng từ worker/tool cũ chấm dứt trước khi worker thay thế thực thi. |
| Teardown local và SSH | Tool/process con thuộc phiên dừng trên từng đường; không chỉ assert port cha hoặc kết nối SSH đã đóng. |
| Phiên phase mới | `thread/start` mới, `thread_id` khác, full prompt đúng live phase, cùng workspace/output được giữ. |
| Tương thích | Continuation cùng phase; chỉ cấu hình review boundary; không cấu hình boundary; chuẩn hóa state; không ép handoff khi active state đổi ngoài boundary đã cấu hình. |
| Admission | Đọc lại status, route và dependency; state ngoài dispatch vẫn không đủ điều kiện; các đường terminal, mất issue, mất route và Blocked giữ behavior dự kiến. |
| Race | Normal completion đồng thời reconcile, worker đã chết và message đến muộn có kiểm soát không gây dispatch trùng, nhả ownership sớm hoặc làm sai trạng thái worker thay thế. |
| Stop chưa rõ kết quả | Giữ claim/slot và recovery bền vững, lỗi hiển thị rõ, poll tiếp theo không redispatch, cần operator recovery. |
| Restart giữa handoff | Trước xác nhận và sau xác nhận/trước redispatch: giữ output, recovery pending và không tự mở worker thay thế trước khi operator xác nhận. |
| Controls | Không rò rỉ turn permit; giữ pause/drain; bằng chứng cleanup không dựa vào giả định `after` hoặc `finally` đã chạy. |
| Tracker/config | Không coi lỗi đọc là đổi boundary; giữ kiểm sau turn; giữ coverage reload và yêu cầu drain/restart hiện có khi đổi profile. |
| Continuation | Cho phép kết thúc tại boundary của assignment, tránh khảo sát lại không cần thiết trong cùng phase, không cấp quyền của phase tiếp theo. |

Dùng Elixir 1.19.x / OTP 28 theo [hướng dẫn Elixir](../elixir/AGENTS.md). Chạy focused `mix test`, sau đó `make -C elixir all`. Required CI vẫn là `make-all` và `pr-description-lint`; không thêm pipeline cho fix này.

Source đủ điều kiện ready khi có bằng chứng fail-before/pass-after, mọi invariant/check liên quan đạt, docs nhất quán và review cuối hoàn tất. Draft thiếu gate vẫn chưa hoàn thành dù code đã push. Maintainer merge hoàn tất implementation issue theo workflow repo; runtime adoption là mốc riêng.

## Tham chiếu rollout QA cho công việc sau

Phần này giữ lại ý định rollout ban đầu để giao riêng về sau; không thuộc phạm vi implementation source đã được duyệt.

1. Kiểm lại service QA, workflow/override có hiệu lực, hash binary đang chạy và runtime-control membership. Lưu binary/revision cũ cùng bằng chứng cần rollback.
2. Pause/drain QA, đối soát worker/output/PR/recovery và dừng instance cũ trước khi thay runtime. Giữ concurrency và quyền đã cấp; tránh tác động service khác qua binary hoặc symlink dùng chung.
3. Deploy runtime đã kiểm chứng tới riêng QA. Kiểm executable thực chạy, workflow đã nạp và trạng thái pause trước khi resume.
4. Dùng một QA Subtask được coordinator giao làm canary. Ghi issue, phase, thread/turn IDs, thời điểm stop/start, workspace và recovery. Không reset SIGN-164 khỏi Done để test.
5. Chỉ nghiệm thu khi Ready, Progress và In Review có thread độc lập, không chồng worker và giữ được output/recovery. Model tự kết thúc turn chưa chứng minh interrupt giữa turn; regression deterministic cung cấp bằng chứng đó. Mở lại queue QA sau nghiệm thu; các service khác cần được giao rollout riêng.

Nếu stop, ownership, recovery hoặc isolation sai: pause/drain QA, giữ bằng chứng/output, đối soát mutation đã xảy ra rồi khôi phục binary đã lưu khi phù hợp. Rollback binary không hoàn tác thao tác ghi tracker, merge hoặc dữ liệu. Binary cũ vẫn có lỗi boundary; service khởi động thành công chưa đủ để mở lại queue.

## Ngoài phạm vi và trạng thái hiện tại

Review hồi cứu bằng chứng/comparator của QA PR #14, closure SIGN-144, cleanup SIGN-164 và nghiệm thu các scenario là công việc riêng. Thay đổi này không xác nhận các kết quả đó. Không bao gồm credential fencing, đổi model/quyền, tăng concurrency, audit QA diện rộng hoặc rollout mọi service.

Lượt lưu ban đầu chỉ thêm plan. Lượt triển khai tiếp theo đã sửa source/test/docs và chạy kiểm chứng trong bản sao cô lập tại `/tmp/symphony-phase-boundary-20261016` trên server. Không thay service, binary production hoặc tracker live.

## Bằng chứng triển khai và gate còn mở

- Regression Ready → Progress giữa turn thất bại trên baseline: worker không phát `DOWN` sau reconcile khi chưa có `turn/completed`.
- Ma trận mới kiểm Ready → Progress, Progress → In Review và In Review → Progress trên local và SSH thật qua một sshd tạm chỉ lắng nghe loopback. Fixture dùng key/known-hosts tạm, không thay SSH production; không đưa private key vào repo.
- Các case kiểm dừng process con cùng group, giữ output, retry qua live admission, `thread_id` mới/full prompt, bỏ message cũ, giữ ownership khi stop chưa rõ và pause recovery sau restart đã được thêm. Marker handoff được giữ qua normal completion và các lần retry; Orchestrator đồng bộ chuẩn bị boundary trước teardown.
- Startup cleanup giữ workspace của handoff pending kể cả khi live issue đã sang Done; lỗi khôi phục ledger cũng chặn cleanup đầu phiên. Regression kiểm giữ output qua trường hợp này.
- Khi worker đã dừng nhưng phiên thay thế chưa nhận workspace, marker recovery vẫn được giữ. Retry handoff không tự chuyển sang host khác làm mất output.
- Boundary sessions hiện dùng process group Linux qua `setsid`. Nếu còn descendant ở group khác, stop bị coi là chưa xác nhận và giữ ownership; worker có thể đang bị suspend, cần operator kiểm tra trước recovery. Hook sau phiên phải đồng bộ đóng session với Orchestrator trước khi chạy.
- **Blocker containment của candidate lịch sử:** process đã daemonize/reparent hoàn toàn không còn xác định được đầy đủ bằng snapshot group/ancestry. Candidate này chưa chứng minh invariant dừng mọi tool trong trường hợp đó. Không chuyển PR sang ready hoặc rollout cho đến khi giải quyết bằng containment phù hợp và regression tương ứng; không coi đây là debt tùy chọn.
- **Gate nền tảng/recovery:** đường boundary mới cần các công cụ Linux nêu trong Elixir README; chưa kiểm macOS. Recovery bền vững cần runtime control được bật. Khi control dùng chung, pause recovery tác động toàn bộ membership đã cấu hình. Đây là điều kiện phải rà trước nghiệm thu, không được suy ra từ việc tests với control tắt chạy qua.
- Completion gate `make -C elixir all` đã qua trên candidate source với Elixir 1.19.5 / OTP 28: 375 tests, 0 lỗi, 6 live tests được skip; coverage theo cấu hình repo đạt 100%, format/lint/specs/Dialyzer đạt. Cả ba hướng chuyển phase qua local và SSH loopback thật đã chạy, không bị skip trong lượt kiểm chứng này.
- Chín Python tests cho deployment/CI đã qua trong bản sao cô lập. Nội dung PR đã qua `mix pr_body.check`. Required CI và maintainer review vẫn phải đối chiếu trên revision được push; các kết quả test xanh không đóng blocker containment. Merge, deploy và canary chưa được thực hiện.

## Bổ sung containment ngày 2026-10-16

Các kết quả candidate phía trên là lịch sử. Phần triển khai tiếp theo thay process group bằng
transient systemd service/cgroup riêng cho mỗi phiên, bao gồm local và SSH; xem
[contract triển khai, kiểm chứng và recovery](codex-session-containment.md).
Người dùng đã chốt mất SSH/owner thì dừng phiên remote, giữ recovery khi chưa xác nhận stop;
không nối lại turn cũ. Sau kiểm chứng đầy đủ, push trực tiếp main để CI/CD hiện có deploy cả
bốn service, rồi kiểm canary. Không dùng rollout riêng BE trong lượt này.
