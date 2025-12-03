# labhpb
Hiểu rồi, giờ mình chỉ **lên kế hoạch chi tiết, không đụng gì tới file**. Mình chia ra 4 phần: kiến trúc tổng, layout thư mục, nội dung script cho VM1/VM2, và kế hoạch test theo từng giai đoạn.

---

### 1. Kiến trúc tổng (để xong được Lab 2 + Lab 3)

- **VM1 (server)**  
  - Chạy:
    - `etcd` (single-node, port 2379) – phục vụ Lab 3.
    - gRPC **Monitoring Server**:
      - Nhận metrics từ các agent.
      - Dùng **bidirectional streaming** để gửi command xuống agent (Lab 2).
      - Nói chuyện với etcd để:
        - Đọc/ghi config cho từng node: `/monitor/config/<HOSTNAME>`.
        - Theo dõi heartbeat từ agent qua prefix `/monitor/heartbeat/`.
      - Giữ “global view” tình trạng hệ thống (Lab 3).
- **VM2 (agent host)**  
  - Chạy **n agent** (ít nhất 2: `node-a`, `node-b`) dưới dạng nhiều process:
    - Thu thập metric Linux (cpu, mem, disk io, net in/out) bằng shell (`free`, `top`, `iostat`, `ifstat`) hoặc `psutil`.
    - Duy trì gRPC bidirectional stream đến server trên VM1:
      - Gửi metrics `(time, hostname, metric, value)` định kỳ (Lab 2).
      - Nhận command từ server (VD: thay đổi interval, bật/tắt metric) – thực thi nội bộ agent.
    - Kết nối **etcd (VM1)**:
      - Watch key `/monitor/config/<HOSTNAME>` để cập nhật config realtime (Lab 3).
      - Gửi heartbeat lease TTL qua key `/monitor/heartbeat/<HOSTNAME>` (Lab 3).

Toàn bộ **code dùng chung một thư mục project** (bạn sẽ push GitHub rồi clone về cả 2 VM).

---

### 2. Layout thư mục project (trong repo chung)

Dự kiến:

- `proto/monitor.proto`  
  - Định nghĩa:
    - `Metric` (time, hostname, metric, value).
    - `CommandRequest` / `CommandResponse`.
    - Service `MonitorService` với 1 RPC bidirectional streaming `CommandStream` (client gửi Metric & ack, server gửi Command).
- `server/`
  - `server_main.py`:  
    - Khởi tạo gRPC server.
    - Implement `MonitorServiceServicer`:
      - Hàm thực hiện stream: đọc metrics client gửi lên; đồng thời gửi command xuống.
    - Tích hợp etcd:
      - Đọc config cho từng host từ `/monitor/config/<HOSTNAME>`.
      - Watch prefix `/monitor/heartbeat/` để log node alive/dead.
  - (Có thể thêm `state.py`, `command_api.py` nếu cần tách nhỏ.)
- `agent/`
  - `agent_main.py`:
    - Kết nối gRPC tới `vm1:50051`.
    - Mở stream:
      - Loop gửi metrics theo interval hiện tại.
      - Trong cùng stream, lắng nghe command từ server, cập nhật `config` trong bộ nhớ.
    - Tích hợp etcd:
      - Lấy config ban đầu từ `/monitor/config/<HOSTNAME>`.
      - Watch key config để auto update.
      - Gửi heartbeat với lease TTL: `/monitor/heartbeat/<HOSTNAME>`.
  - `metrics_linux.py`: wrapper gọi shell commands và parse output.
- `common/`
  - `config_schema.py`: default config (interval, metrics list).
  - `util_logging.py`: hàm log đơn giản.
- `requirements.txt`
  - `protobuf==3.20.3`
  - `grpcio==1.48.2`
  - `grpcio-tools==1.48.2`
  - `etcd3`
  - (tuỳ chọn `psutil` nếu dùng.)
- `README.md`
  - Hướng dẫn: cách setup VM1, VM2, cách chạy, cách test Lab2/Lab3.

---

### 3. Kế hoạch cho script setup (không dùng lại Kafka script, chỉ học style)

#### 3.1. Script cho VM1 (ví dụ: `vm1_lab_setup.sh`)

**Mục tiêu**: cài mọi thứ để VM1 sẵn sàng cho Lab2+3.

- Khung giống `vm1_setup.sh`:
  - `set -euo pipefail`, check `sudo`, hàm `info/warn/err`, `_autodetect_ip`.
- Các bước chính:
  1. **Cài OS packages**  
     - `apt-get update`  
     - `apt-get install -y --no-install-recommends python3 python3-venv python3-pip git tmux etcd-server sysstat ifstat ufw`.
  2. **Clone project**  
     - VD vào `/opt/monitor-lab`:
       - Nếu chưa tồn tại: `git clone <repo> /opt/monitor-lab`.
       - Nếu có rồi: `git pull` (hoặc bỏ qua).
  3. **Tạo virtualenv + cài pip packages**  
     - `python3 -m venv /opt/monitor-lab/.venv` (nếu chưa).
     - `pip install -r requirements.txt`.
  4. **Generate code từ `.proto`**  
     - Chạy `python -m grpc_tools.protoc ... proto/monitor.proto`.
  5. **Setup etcd (single-node)**  
     - Sử dụng `systemctl enable --now etcd` (nếu dùng package chuẩn) hoặc tạo service riêng (nếu chạy container/binary).
     - Đảm bảo port 2379 open cho VM2.
  6. **Tạo systemd service cho gRPC server**  
     - File `monitor-server.service`:
       - `WorkingDirectory=/opt/monitor-lab`.
       - `ExecStart=/opt/monitor-lab/.venv/bin/python -m server.server_main --bind 0.0.0.0:50051`.
     - `systemctl daemon-reload`.
  7. **(Tuỳ chọn) Mở firewall**  
     - Nếu `ufw` active: `ufw allow 50051/tcp` và `ufw allow 2379/tcp`.
  8. **In SUMMARY**  
     - THIS_IP, GRPC_PORT, etcd endpoint, path project, cách start:  
       - `sudo systemctl start monitor-server`.

#### 3.2. Script cho VM2 (ví dụ: `vm2_lab_setup.sh`)

**Mục tiêu**: chuẩn bị nhiều agent kết nối tới VM1.

- Khung giống `vm2_setup.sh`:
  - `set -euo pipefail`, check root, `_autodetect_ip`.
- Các bước chính:
  1. **Cài OS packages**  
     - `python3`, `python3-venv`, `python3-pip`, `git`, `tmux`, `sysstat`, `ifstat`, `ufw`.
  2. **Clone cùng repo**  
     - Cùng repo Git như VM1, ví dụ `/opt/monitor-lab`.
  3. **Tạo venv + cài pip**  
     - Giống VM1, dùng chung `requirements.txt`.
  4. **Generate proto** (tuỳ, có thể dùng cùng lệnh như VM1).
  5. **Tạo script chạy agent**  
     - Ví dụ `/opt/monitor-lab/run_agents.sh`:
       - Chạy 2 process:
         - `agent_main.py --hostname node-a --server vm1:50051 --etcd-endpoint vm1:2379`
         - `agent_main.py --hostname node-b --server vm1:50051 --etcd-endpoint vm1:2379`
  6. **(Tuỳ chọn) systemd services cho từng agent**  
     - `monitor-agent-node-a.service`, `monitor-agent-node-b.service` hoặc chạy bằng `tmux`.
  7. **In SUMMARY**  
     - THIS_IP, SERVER_IP (VM1), cách start agents.

---

### 4. Kế hoạch kiểm tra theo giai đoạn (để bạn chắc chắn xong Lab 2, rồi Lab 3)

#### Giai đoạn 0 – Network cơ bản
- Ping 2 chiều `vm1 ↔ vm2`.
- Kiểm tra port:
  - Sau khi server chạy: từ VM2 `nc -vz vm1 50051`.
  - `nc -vz vm1 2379` cho etcd.

#### Giai đoạn 1 – Lab 2, không dính etcd (đơn giản trước)
1. Trên VM1:
   - Start `monitor-server` (gRPC).
2. Trên VM2:
   - Start 1 agent `node-a` (chưa cần etcd).
3. Kiểm tra:
   - Server log nhận metrics `(time, hostname, metric, value)`.
   - Gửi 1 command test (VD bằng CLI nhỏ):
     - `python send_command.py --host node-a --action set_interval --payload '{"interval": 2}'`.
   - Thấy agent đổi interval gửi metric.

=> Hoàn thành **yêu cầu chính Lab 2**: nhiều client (sau đó bạn start thêm `node-b`) + server gửi command qua bidirectional streaming.

#### Giai đoạn 2 – Thêm etcd config (Lab 3, phần config)
1. Đảm bảo etcd server trên VM1 chạy, có thể `etcdctl member list`.
2. Trên VM1:
   - Đặt config cho từng node:
     - `/monitor/config/node-a`, `/monitor/config/node-b` với JSON `<interval, metrics>`.
3. Agent trên VM2:
   - Khi start, đọc config từ etcd.
   - Watch key config, log ra khi có thay đổi.
4. Thử:
   - `etcdctl put /monitor/config/node-a '{"interval":5,...}'`.
   - Quan sát agent `node-a` log “config updated” và đổi behavior.

#### Giai đoạn 3 – Heartbeat + server monitor heartbeat (Lab 3, phần heartbeat)
1. Agent:
   - Mỗi agent định kỳ:
     - `put /monitor/heartbeat/<HOSTNAME>` với lease TTL, refresh.
2. VM1 server:
   - Có process dùng etcd3:
     - `add_watch_prefix_callback("/monitor/heartbeat/", ...)`.
     - In `[+] node X alive` khi Put, `[-] node X dead` khi Delete.
3. Thử:
   - Đang chạy 2 agent -> server log cả 2 alive.
   - Tắt process `node-b` → sau một lúc etcd lease hết hạn → server in log node-b dead.

=> Kết thúc: bạn đã cover toàn bộ yêu cầu Lab 2 + Lab 3 trong cùng project.

