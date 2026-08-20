# Ghép DAG với code của Noel — trạng thái và việc còn lại

Cập nhật sau khi nhận cấu trúc repo của Noel.

## Đã chỉnh trong DAG

| Thay đổi | Lý do |
|---|---|
| Bỏ task `refresh_matviews` | Noel dùng `CREATE OR REPLACE VIEW` thường, không có materialized view nào |
| Bỏ task `generate_batch` | Batch đã sinh sẵn thành thư mục `data/batches/batch_YYYYMMDD/` |
| Thêm task `pick_batch` | Tự tìm batch kế tiếp chưa nạp, đối chiếu với `ops.load_audit` |
| Thay 4 task Python `load_raw_*` bằng 1 BashOperator | Gọi `scripts/load_raw.sh` của Noel, dùng COPY nên nhanh hơn |
| Đổi `02_stg_clean.sql` sang `02_stg_orders.sql` | Khớp tên file Noel đặt |
| Đổi `seed/01_stg_static.sql` sang `transform/01_stg_static.sql` | Khớp vị trí Noel đặt |
| `write_audit` từ Python đổi sang gọi `04_write_audit.sql` | Noel đã viết file này |
| DAG seed nạp từ `data/batches/seed/` bằng `load_raw.sh` | Khớp cấu trúc thật, không đọc `data/raw/` nữa |

## Hệ quả quan trọng: dashboard tự update giờ phụ thuộc 100% vào cache

Không có materialized view nghĩa là view tính lại real-time mỗi lần Superset
query — về nguyên tắc thì tốt, dữ liệu luôn mới. Nhưng cũng nghĩa là **không còn
lớp phòng hộ nào**: nếu ai đó bật lại cache Superset, dashboard sẽ đứng số và
không có task refresh nào cứu.

`superset/superset_config.py` đã đặt `NullCache` cho cả bốn loại cache. Đừng đổi.

Đánh đổi cần biết: 18 view thường chạy lại toàn bộ mỗi lần query. Nếu dashboard
chậm khi Noel dùng qua Tailscale, nguyên nhân là chỗ này chứ không phải mạng.
Cách xử lý đúng là tối ưu view, không phải bật cache.

## Cách batch được chọn — khác thiết kế ban đầu

Batch của Noel đặt tên theo **ngày trong dữ liệu** (`batch_20180801`), không phải
theo thời điểm Airflow chạy. Dữ liệu Olist là 2016-2018 nên `logical_date` của
Airflow vô nghĩa ở đây.

Nên `pick_batch` làm thế này: liệt kê thư mục `batch_*`, bỏ những `batch_id` đã
có trong `ops.load_audit`, lấy cái nhỏ nhất còn lại. Mỗi run tiến đúng một batch.

Ưu điểm: idempotent, chạy lại không nạp trùng, và khớp đúng kịch bản "mỗi ngày
thêm dữ liệu mới" mà chị yêu cầu.

Khi hết batch, task raise `AirflowSkipException` — run hiện màu hồng (skipped)
chứ không đỏ (failed). Đúng ngữ nghĩa, và không làm bẩn Grid view khi demo.

## Việc còn phải làm

### 1. Nạp credential vào Airflow Variable

`load_raw.sh` cần biến `PGHOST` / `PGUSER` / `PGPASSWORD`. DAG truyền qua
`var.value.get(...)`, nên chạy một lần sau khi `make up`:

```bash
make set-vars
docker compose exec airflow-scheduler airflow variables list
```

### 2. Kiểm tra load_raw.sh dùng biến gì

Hiện đang giả định script đọc biến môi trường chuẩn của psql
(`PGHOST`, `PGPORT`, `PGDATABASE`, `PGUSER`, `PGPASSWORD`). Mở file xem thực tế:

```bash
head -30 scripts/load_raw.sh
```

Nếu script hardcode `-h localhost` hoặc dùng tên biến khác, báo Noel sửa thành
biến môi trường, hoặc sửa phần `env` trong BashOperator cho khớp.

Chú ý: trong container Airflow thì host là `postgres`, **không phải** `localhost`.

### 3. Kiểm tra đường dẫn script mong đợi

Noel đưa ví dụ `./scripts/load_raw.sh /data/batches/seed seed` — đường dẫn
`/data/...`. Trong container Airflow, `./data` được mount vào
`/opt/airflow/data`, nên DAG truyền `/opt/airflow/data/batches/...`.

Nếu script hardcode `/data` bên trong thay vì dùng tham số, có hai cách: thêm
mount `./data:/data` vào compose, hoặc nhờ Noel bỏ hardcode. Cách hai sạch hơn.

### 4. Xác nhận batch_id là gì

Noel nói `raw.raw_orders` có `batch_id` tới `20180804`, nhưng thư mục tên
`batch_20180804`. Cần biết chính xác script ghi giá trị nào vào cột `batch_id`:

```bash
docker compose exec postgres psql -U olist_user -d olist \
  -c "SELECT DISTINCT batch_id FROM raw.raw_orders ORDER BY 1;"
```

Nếu là `20180804` (không có tiền tố) thì `pick_batch` phải cắt tiền tố trước khi
đối chiếu — sửa một dòng.

### 5. Thứ tự write_audit

Noel đề xuất thứ tự `load_raw` rồi `stg` rồi `write_audit` rồi `mart_upsert`.
Hiện đặt `write_audit` **sau** `mart_upsert` để `rows_loaded` phản ánh số dòng
thực vào fact.

Nếu `04_write_audit.sql` chỉ đọc từ staging thì hai cách đều chạy, nhưng đặt sau
cho số liệu đúng hơn. Mở file xem nó SELECT từ bảng nào rồi chốt với Noel.

### 6. Hai điều Noel báo

**`batch_20180805` chưa nạp** — tốt, đó chính là batch đầu tiên `pick_batch` sẽ
chọn khi bật DAG. Không cần làm gì.

**`data/lan2/batch_20180804/`** — trùng tên batch nhưng nằm ngoài `data/batches/`.
`pick_batch` chỉ quét `data/batches/` nên không ảnh hưởng. Nhưng nếu đây là bản
chạy lại lần 2 để chứng minh tính idempotent thì hữu ích cho Run 5 trong kịch bản
evidence: copy nó vào `data/batches/` và xem `rows_loaded = 0`.

Hỏi Noel xem có phải chủ đích không.

## Thứ tự chạy lần đầu

```bash
make up
make set-vars                 # nạp credential cho load_raw.sh
make dag-list                 # thấy 2 DAG, không có import error
make seed                     # nạp bảng tĩnh + batch nền
make check-seed               # dimension phải có dữ liệu
make batches                  # xem còn batch nào chưa nạp
make dag-test                 # chạy thử 1 batch
make dag-unpause              # bật schedule
```
