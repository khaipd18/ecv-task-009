# Interface — những gì bên Khải trông đợi từ bên Noel

File này là **hợp đồng một chiều**: liệt kê chính xác những gì phía hạ tầng
(Khải) gọi tới. Noel tuỳ biến bên trong thoải mái, miễn giữ đúng các điểm dưới.

Nếu Noel muốn đổi bất kỳ mục nào, báo Khải để sửa DAG tương ứng — đừng đổi ngầm.

---

## 1. Script sinh batch

DAG `olist_daily_pipeline`, task `generate_batch` gọi:

```bash
python /opt/airflow/scripts/generate_batch.py \
  --batch-id {{ ts_nodash }} \
  --out-dir /opt/airflow/data/batches/{{ ts_nodash }} \
  --state /opt/airflow/data/state/cursor.json
```

Yêu cầu:

| Mục | Giá trị |
|---|---|
| Đường dẫn file | `/opt/airflow/scripts/generate_batch.py` |
| Tham số | `--batch-id`, `--out-dir`, `--state` |
| Output | 4 file CSV trong `--out-dir` |
| Tên file | `orders.csv`, `order_items.csv`, `order_payments.csv`, `order_reviews.csv` |
| Header | Giữ nguyên tên cột gốc của Kaggle |
| Exit code | Khác 0 khi lỗi, để Airflow biết fail |
| Tính lặp lại | Cố định `random.seed` — chạy máy nào cũng ra dữ liệu giống nhau |

File rỗng là hợp lệ (có ngày không phát sinh review) — DAG xử lý được, chỉ log lại.

**Quy tắc quan hệ:** khi cắt orders của một ngày, phải kéo theo
order_items/payments/reviews của **đúng các order_id đó**. Dòng con mồ côi sẽ
làm fact join hụt và sai số dashboard. Script `capture_evidence.sh` có phần đếm
dòng mồ côi để phát hiện sớm.

---

## 2. File SQL — tên và vị trí

DAG khai báo `template_searchpath="/opt/airflow/sql"` nên đường dẫn là tương đối.

### DAG `olist_seed_static` (chạy 1 lần)

| Task | File SQL |
|---|---|
| `seed_staging` | `seed/01_stg_static.sql` |
| `seed_dimensions` | `seed/02_mart_dimensions.sql` |

### DAG `olist_daily_pipeline` (mỗi run)

| Task | File SQL |
|---|---|
| `stg_clean` | `transform/02_stg_clean.sql` |
| `mart_upsert` | `transform/03_mart_upsert.sql` |
| `refresh_matviews` | `transform/04_refresh_matviews.sql` |

DDL không được DAG gọi — Noel chạy tay một lần hoặc tự thêm vào DAG seed.

Cả ba file trong `transform/` nhận biến `{{ params.batch_id }}`.

---

## 3. Bảng và cột mà DAG đụng trực tiếp

### Bảng raw — task `load_raw_*` insert vào

| File CSV | Bảng đích |
|---|---|
| `orders.csv` | `raw.raw_orders` |
| `order_items.csv` | `raw.raw_order_items` |
| `order_payments.csv` | `raw.raw_order_payments` |
| `order_reviews.csv` | `raw.raw_order_reviews` |

DAG insert đúng các cột có trong header CSV, **cộng thêm cột `batch_id`**.
Nghĩa là DDL phải có tất cả cột gốc của Kaggle (kiểu TEXT) và một cột
`batch_id TEXT`.

### Bảng raw của DAG seed — task `seed_*` dùng COPY

| File CSV trong `data/raw/` | Bảng đích |
|---|---|
| `olist_products_dataset.csv` | `raw.raw_products` |
| `olist_customers_dataset.csv` | `raw.raw_customers` |
| `olist_sellers_dataset.csv` | `raw.raw_sellers` |

Ba bảng này **không** có cột `batch_id` (DAG dùng COPY với đúng header CSV).

### Bảng mà `check_seed` kiểm tra

`mart.dim_product`, `mart.dim_customer`, `mart.dim_seller` — phải tồn tại và có
dữ liệu, nếu không pipeline chính bị chặn ngay task đầu.

### Bảng audit — task `write_audit` insert vào

```sql
CREATE TABLE ops.load_audit (
    id            BIGSERIAL PRIMARY KEY,
    batch_id      TEXT NOT NULL,
    run_time      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    rows_in       INTEGER,
    rows_dup      INTEGER,
    rows_rejected INTEGER,
    rows_loaded   INTEGER
);
```

DAG insert theo đúng thứ tự `(batch_id, run_time, rows_in, rows_dup,
rows_rejected, rows_loaded)`.

### Bảng mà `dq_check` kiểm tra

`mart.fct_order_items`, ba cột: `order_id` (không NULL), `order_item_id`
(không NULL), `price` (>= 0). Đổi tên cột thì báo Khải sửa `column_mapping`.

---

## 4. XCom — số liệu cho bảng audit

Task `write_audit` gom số liệu từ XCom của các task trước. Nếu Noel viết SQL
thuần thì các key này sẽ trống và audit ghi 0.

| Task | XCom key | Ý nghĩa |
|---|---|---|
| `load_raw.load_raw_*` | `rows` | Đã có sẵn, Khải lo |
| `stg_clean` | `rows_rejected` | Số dòng bị loại |
| `mart_upsert` | `rows_dup` | Số dòng trùng bị bỏ |
| `mart_upsert` | `rows_loaded` | Số dòng thực insert |

Ba key sau cần Noel trả về. Cách đơn giản nhất: file SQL kết thúc bằng một
`SELECT` trả về các con số đó, rồi báo Khải để wire vào XCom. Hoặc ghi thẳng vào
một bảng tạm và `write_audit` đọc từ đó — báo Khải nếu chọn cách này.

Nếu chưa kịp, audit vẫn chạy và ghi 0 — pipeline không fail.

---

## 5. Kết nối cho Superset

Noel dùng user read-only, chỉ đọc được `mart` và `ops`:

```
Host:     postgres
Port:     5432
Database: olist
Username: superset_ro
```

Không đọc được `raw` và `staging` — cố ý, để chart không lỡ trỏ vào dữ liệu bẩn.
Cần thêm quyền thì báo Khải.

---

## 6. Những gì Noel KHÔNG cần đụng

`docker-compose.yml`, `docker/`, `superset/superset_config.py`, `dags/`,
`Makefile`, `scripts/capture_evidence.sh`.

Cache Superset đã tắt sẵn trong `superset_config.py`. Nếu dashboard không tự
update thì kiểm tra `refresh_matviews` đã chạy chưa, đừng sửa config.
