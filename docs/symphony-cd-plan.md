# Plan: tự động deploy Symphony khi main cập nhật

Ngày: 2026-10-16. Trạng thái: đã chốt phạm vi; implementation và các bước kích hoạt
được ghi trong [handoff](symphony-cd-handoff.md).

## Mục tiêu đã thống nhất

Push hoặc merge vào `main` → CI và build thành công → tự deploy lên server.

Giữ cách vận hành hiện tại: binary Burrito, `systemd --user`, kết nối qua
Tailscale + SSH. Không cần duyệt deploy hay thao tác Pause/Resume mỗi lần.

Các quyết định đã được người dùng xác nhận ngày 2026-10-16:

- Mỗi lần deploy cập nhật cả bốn service: BE, FE, Landing và QA.
- Restart ngay sau khi artifact sẵn sàng và các kiểm tra trước deploy đạt;
  không chờ agent hoàn thành. Chấp nhận ngắt lượt đang chạy để giữ CD đơn giản.
- Nếu triển khai bản mới thất bại, tự rollback về bản trước và báo workflow
  thất bại, kể cả khi rollback thành công.

## Hiện trạng liên quan

- Repo: `signapse-group/signapse-symphony`.
- CI `make-all` và build `burrito-nightly` đã chạy trên push vào `main`, nhưng
  đang độc lập. CD phải kiểm tra cả hai thành công trên cùng commit.
- Server: `dgminhtam-server`, IP Tailscale `100.113.56.38`, user `dgminhtam`,
  Ubuntu x86-64. SSH config và key hiện có dùng cho khảo sát từ máy local.
- Bốn service đang dùng binary release `850924f`:

  | Service | Port |
  | --- | --- |
  | `symphony.service` — BE | 4000 |
  | `symphony-fe.service` | 4001 |
  | `symphony-landing.service` | 4002 |
  | `symphony-qa.service` | 4003 |

- Runtime nằm tại `/opt/apps/symphony/runtime`; đã có thư mục `releases/`.
- Có script triển khai cũ trong
  `/opt/apps/symphony/runtime/ops/workflow-button-deploy-20261013/` để tham khảo.
  Script cố định SHA, chỉ xử lý ba service và yêu cầu Paused; cần giản lược,
  thêm QA trước khi dùng cho CD mới.

## Phương án tối thiểu

### 1. Workflow CD

Thêm `.github/workflows/deploy.yml`:

- Nhận sự kiện hoàn tất từ `make-all` và `burrito-nightly` trên push `main` của
  đúng repo. Chỉ deploy khi cả hai thành công trên cùng SHA.
- Nếu một bên chưa xong, kết thúc lượt kiểm tra; sự kiện hoàn tất của bên còn
  lại sẽ kiểm tra tiếp. Không cần vòng chờ. Bỏ qua commit đã bị main mới thay thế.
- Tải artifact `linux_x86_64` và checksum từ đúng build run. Không tải qua
  đường dẫn release `nightly` có thể bị thay thế.
- Kết nối Tailscale, chuyển artifact và gọi script deploy qua SSH.
- Chỉ cho một lượt deploy chạy tại một thời điểm; không hủy lượt đang đổi runtime.
  Không để lượt cũ triển khai đè lên bản mới hơn.

### 2. Script deploy nhỏ

Thêm `scripts/deploy_symphony.py`, dùng Python standard library trên server.

1. Kiểm tra checksum, stage binary vào `runtime/releases/<sha>/`.
2. Ghi nhận release và cấu hình service trước khi thay đổi.
3. Cập nhật đường dẫn binary và install directory riêng của từng service;
   giữ cấu hình `ERL_FLAGS`/`sys.config` cần cho dashboard qua Tailscale.
4. Restart ngay cả bốn service bằng `systemctl --user`, không chờ hết lượt
   agent đang chạy và không thêm điều kiện idle/Paused.
5. Chờ service hoạt động và kiểm tra `/api/v1/state` trên bốn port. JSON phải
   không có lỗi snapshot/database và có đủ heartbeat thành viên; HTTP 200
   riêng lẻ chưa đủ. Không yêu cầu hệ thống phải ở trạng thái Paused.
6. Nếu đổi runtime, restart hoặc kiểm tra sức khỏe thất bại sau khi bắt đầu
   thay đổi service, tự khôi phục binary/cấu hình trước đó và restart lại.
   Kiểm tra sức khỏe bản khôi phục và báo rõ kết quả rollback. Workflow vẫn
   thất bại kể cả khi rollback thành công.

Không reset checkout nghiệp vụ, sửa `WORKFLOW.md`, xóa workspace/log hoặc
thay secrets. Giữ nguyên các SQLite runtime-control; rollback binary không
tự động phục hồi database cũ. QA hiện có thay đổi local và kết quả kiểm thử
chưa commit, cần được giữ nguyên.

### 3. Thiết lập một lần

- Cấu hình identity Tailscale cho GitHub Actions và quyền tới server.
- Cấu hình SSH credential riêng cho CD cùng host key đã xác minh; không sao
  chép private key cá nhân vào repo hoặc plan.
- Chuẩn hóa phần cấu hình chọn release của bốn service để script cập nhật
  được, đồng thời giữ nguyên cấu hình nghiệp vụ hiện có.
- Cập nhật ngắn tài liệu vận hành và quy định deployment hiện tại để phản ánh
  việc deploy tự động sau CI thay cho triển khai thủ công của maintainer.

## Phạm vi không làm

Không thêm Docker/Kubernetes, staging, API điều khiển, Pause/Resume tự động,
approval gate hay hệ thống triển khai riêng. Giữ CI/build hiện có; không chạy
build trên production server.

## Kiểm chứng khi triển khai

- CI lỗi hoặc artifact sai checksum: không đổi runtime.
- Deploy đúng SHA thành công: cả bốn service dùng bản mới và health đạt.
- Bản mới không khởi động được: quay về bản trước và báo lỗi rõ ràng.
- Secrets, database, workflow nghiệp vụ và workspace vẫn được giữ nguyên.
- Có kiểm thử nhỏ cho script, đặc biệt nhánh lỗi/rollback; chạy completion
  gate của repo `make -C elixir all` trước khi bàn giao implementation.

## Đánh đổi và điểm bàn tiếp

- Mỗi lần deploy có gián đoạn ngắn và có thể ngắt lượt agent đang chạy.
  Không cam kết tiếp tục được chính xác lượt đang dang dở.
- Rollback binary chỉ an toàn nếu bản mới chưa thay đổi dữ liệu theo cách
  không tương thích; thay đổi schema phải được xem xét riêng.
- Runner dùng Tailscale OAuth client và `tag:ci` như repo BE, cùng SSH key
  riêng cho CD. Các bước dùng lại credential được ghi cụ thể trong handoff.

Tham khảo handoff để biết trạng thái cấu hình GitHub/server và kiểm chứng thực tế.
