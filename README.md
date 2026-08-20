# Olist E-commerce Data Pipeline

Pipeline dữ liệu cho bộ Olist Brazilian E-Commerce: nạp CSV thô → làm sạch →
mart phục vụ Superset. Postgres chạy trong container Docker, 4 schema tách
biệt theo tầng: `raw` / `staging` / `mart` / `ops`.

## Kết nối

```
Container : olist-dev
Database  : olist
User      : postgres
```

```bash
docker exec -i olist-dev psql -U postgres -d olist -v ON_ERROR_STOP=1 -q < file.sql
```

## Cấu trúc thư mục

```
sql/
├── ddl/                        -- khai báo bảng (DROP + CREATE TABLE), chạy 1 lần khi build lại schema
│   ├── 01_raw.sql               -- tầng raw: mọi cột TEXT, không ép kiểu, không làm sạch
│   ├── 02_staging.sql           -- tầng staging: đã ép kiểu, đã có CHECK constraint
│   ├── 03_mart.sql              -- tầng mart: 2 bảng fact + 3 bảng dim + index
│   └── 04_ops.sql               -- ops.load_audit + ops.rejected_rows
├── transform/                   -- ETL, chạy MỖI LẦN nạp batch (theo thứ tự bên dưới)
│   ├── 01_stg_static.sql        -- staging cho 4 bảng tĩnh (products/customers/sellers/category_translation)
│   ├── 02_stg_orders.sql        -- raw -> staging cho 4 bảng động, nhận :batch_id, tự đẩy dòng lỗi sang ops.rejected_rows
│   ├── 03_mart_upsert.sql       -- staging -> mart, chạy TOÀN BỘ lịch sử mỗi lần (không lọc theo batch)
│   └── 04_write_audit.sql       -- ghi ops.load_audit cho 1 batch, nhận :batch_id, xoá-rồi-ghi nên chạy lại được
└── marts/                       -- view cho Superset đọc, mỗi file 1 chủ đề
    ├── 01_overview.sql          -- KPI ngày, Pareto category, doanh thu theo bang, chi tiết drill-down
    ├── 02_product.sql           -- heatmap category×phân khúc, scatter hiệu suất category, tăng trưởng MoM
    ├── 03_seller.sql            -- scorecard seller, mức độ tập trung doanh thu (Lorenz curve)
    ├── 04_delivery_customer.sql -- hiệu suất giao hàng, độ trễ vs review, khách mua 1 lần vs mua lại
    └── 05_data_quality.sql      -- tổng hợp audit, thống kê lỗi, sức khoẻ pipeline tổng

scripts/
├── generate_batch.py            -- cắt CSV gốc thành seed + các batch ngày, CỐ Ý chèn lỗi để test pipeline
├── load_raw.sh                  -- nạp 1 thư mục batch vào tầng raw (bash, gọi tay, KHÔNG có Airflow)
└── profile_olist.py             -- profiling dữ liệu gốc (ra ket_qua.txt)

data/
├── batches/
│   ├── seed/                    -- dữ liệu lịch sử tới 2018-07-31 + 4 bảng tĩnh
│   ├── batch_20180801/          -- các batch ngày, mỗi batch 4 file: orders/order_items/order_payments/order_reviews
│   ├── batch_20180802/
│   ├── batch_20180803/
│   ├── batch_20180804/
│   └── batch_20180805/          -- ĐÃ có file nhưng CHƯA nạp vào raw (xem mục "Việc chưa làm" bên dưới)
├── raw/                         -- CSV gốc tải từ Kaggle (input cho generate_batch.py)
└── lan2/batch_20180804/         -- thư mục lạ, trùng tên batch_20180804 nhưng nằm ngoài batches/ — chưa rõ mục đích, chưa đụng vào

ket_qua.txt                      -- output của profile_olist.py: schema + null% của 9 file CSV gốc
```

## Kiến trúc 4 tầng

| Tầng | Đặc điểm |
|---|---|
| `raw` | Mọi cột `TEXT`, không ép kiểu. Có `batch_id` + `ingested_at`. Mục đích: dữ liệu bẩn vẫn nạp được, không làm fail cả batch. |
| `staging` | Đã ép kiểu, có `CHECK` constraint (giá >=0, review_score 1-5...), có PK. Dòng ép kiểu lỗi bị đẩy sang `ops.rejected_rows` thay vì fail. |
| `mart` | Đã join sẵn, chỉ đọc. 2 bảng fact **khác grain** + 3 bảng dim + view. Đây là tầng Superset trỏ vào. |
| `ops` | Nhật ký vận hành: `load_audit` (đếm rows_in/dup/rejected/loaded mỗi lần chạy), `rejected_rows` (từng dòng lỗi kèm lý do + payload gốc). |

### 2 bảng fact ở mart — khác grain, đây là điểm dễ sai nhất

| Bảng | Grain | Có gì | Không có gì |
|---|---|---|---|
| `mart.fct_order_items` | 1 dòng = 1 sản phẩm trong 1 đơn | category_en, price_segment, customer_state, seller_state | payment_type_main, review_score, delivery_days |
| `mart.fct_orders` | 1 dòng = 1 đơn | payment_type_main, review_score, delivery_days, is_late | category_en, price_segment, customer_state, seller_state |

**Quy tắc đã đính chính qua thực tế viết view:** `fct_orders` có đúng 1 dòng
/ `order_id` (PK), nên `LEFT JOIN` nó vào `fct_order_items` theo `order_id`
là quan hệ **nhiều-một**, an toàn để lấy cột NHÃN (payment_type_main,
review_score, is_late...). Điều **cấm thật sự** là `SUM`/tổng hợp một cột
SỐ của `fct_orders` (vd `payment_value`) SAU KHI đã join xuống grain sản
phẩm — giá trị đó bị lặp lại trên mỗi dòng sản phẩm của đơn, `SUM` sẽ nhân
sai theo số sản phẩm. Khi cần cộng dồn số liệu ở grain đơn, phải gộp
`fct_orders` về đúng grain đó (qua CTE `GROUP BY`) TRƯỚC khi join.

Ngược lại, khi cần một chỉ số grain-đơn (review, delivery) THEO một chiều
chỉ có ở `fct_order_items` (category, seller...), cách an toàn là: lấy
tập `(chiều đó, order_id)` DISTINCT từ `fct_order_items`, JOIN nhiều-một
sang `fct_orders`, rồi `AVG`/`COUNT` theo chiều đó — không bao giờ `SUM`.

Tổng doanh thu toàn sàn (base để đối chiếu mọi con số %): **14.916.406,70**
(`SUM(item_revenue)` từ `mart.fct_order_items`, khớp ở mọi view có cột
`revenue`/`pct_of_total`).

## Quy trình chạy pipeline (thủ công, chưa có Airflow)

Không có DAG/orchestration nào trong repo — `load_raw.sh` là bash script
gọi tay, không phải task Python. Thứ tự bắt buộc cho 1 batch:

```bash
# 1. Nạp CSV vào raw
./scripts/load_raw.sh /data/batches/batch_20180805 20180805

# 2. Raw -> staging (đẩy dòng lỗi sang ops.rejected_rows)
docker exec -i olist-dev psql -U postgres -d olist -v ON_ERROR_STOP=1 \
  -v batch_id=20180805 < sql/transform/02_stg_orders.sql

# 3. Ghi audit cho batch này (xoá-rồi-ghi, chạy lại an toàn)
docker exec -i olist-dev psql -U postgres -d olist -v ON_ERROR_STOP=1 \
  -v batch_id=20180805 < sql/transform/04_write_audit.sql

# 4. Staging -> mart (chạy TOÀN BỘ lịch sử, không lọc theo batch --
#    vì các chỉ số như "khách mua lại"/"tổng chi tiêu" phụ thuộc cả lịch sử)
docker exec -i olist-dev psql -U postgres -d olist -v ON_ERROR_STOP=1 \
  < sql/transform/03_mart_upsert.sql
```

Bảng tĩnh (products/customers/sellers/category_translation) chỉ nạp 1 lần
từ `data/batches/seed/` qua `sql/transform/01_stg_static.sql`, không lặp
lại cho các batch ngày sau.

## Batch dữ liệu test — lỗi được chèn CÓ CHỦ ĐÍCH

`scripts/generate_batch.py` cắt CSV gốc thành `seed` + các batch ngày, mỗi
batch được thiết kế với 1 loại vấn đề khác nhau để test từng cơ chế xử lý
của pipeline — **không phải bằng chứng "pipeline tốt dần lên" theo thời
gian**, đã xác minh bằng số liệu audit thật:

| Batch | Đặc điểm thiết kế | rows_dup | rows_rejected | quality_score |
|---|---|---|---|---|
| `seed` | Lịch sử tới 2018-07-31, sạch | 0 | 0 | 100% |
| `20180801` | Sạch | 0 | 0 | 100% |
| `20180802` | Có dòng trùng | 193 | 0 | 86,56% |
| `20180803` | Có lỗi định dạng (timestamp, price âm...) | 0 | 86 | 93,38% |
| `20180804` | Hỗn hợp cả hai | 90 | 146 | 80,40% |
| `20180805` | File đã có sẵn, **chưa nạp** | — | — | — |

8 loại `reject_reason` khác nhau (đếm theo cặp `source_table` +
`reject_reason`, vì cùng 1 chuỗi lý do — vd `"khong tim thay don hang cha"`
— được tái dùng ở nhiều bảng), xem chi tiết qua `mart.vw_reject_summary`.

## 7 quy tắc bắt buộc khi viết view mart (đặt ra từ đầu dự án)

1. ~~Không join thẳng `fct_order_items` với `fct_orders`~~ → **đã đính
   chính**: join theo `order_id` (nhiều-một) an toàn cho cột NHÃN; cấm
   `SUM` cột SỐ của `fct_orders` sau khi join xuống grain khác (xem mục
   kiến trúc ở trên).
2. Mọi view phải nói rõ trong 7 cột filter chuẩn — `order_purchase_date`,
   `category_en`, `price_segment`, `customer_state`, `seller_state`,
   `order_status`, `payment_type_main` — giữ được cột nào, mất cột nào và
   vì sao. Không được âm thầm bỏ.
3. `delivery_days` / `delay_days` / `is_late` chỉ tính khi
   `order_status = 'delivered'`.
4. Đếm khách phải `COUNT(DISTINCT customer_unique_id)` (không dùng
   `customer_id` — Olist sinh ID mới cho mỗi đơn).
5. Đếm đơn trong `fct_order_items` phải `COUNT(DISTINCT order_id)`, không
   đếm dòng.
6. `CREATE OR REPLACE VIEW` thường — **không có materialized view nào**
   trong dự án (chưa có unique index để `REFRESH CONCURRENTLY`).
7. Comment tiếng Việt có dấu, dùng `--`, giải thích chi tiết như viết tay.

## Danh mục view (`sql/marts/`)

### `01_overview.sql`
| View | Grain | Ghi chú |
|---|---|---|
| `vw_daily_kpi` | 1 ngày | revenue/orders/customers/aov/items_sold + avg_review_score, on_time_rate (FULL JOIN 2 CTE gộp riêng theo grain ngày) |
| `vw_category_contribution` | 1 category (74 dòng) | Pareto: `pct_of_total`, `pct_cumulative`, `rank_revenue` + `category_display` (top 15 giữ tên, còn lại gộp nhãn `'Others'`, **không gộp dòng**) |
| `vw_state_revenue` | 1 bang khách | revenue/orders/customers + avg_delivery_days/on_time_rate (join `dim_customer` để lấy state cho `fct_orders`) |
| `vw_detail_items` | 1 sản phẩm/đơn | Giữ đủ **7/7 cột filter** — LEFT JOIN `fct_orders` lấy thêm `payment_type_main`/`review_score`/`is_late`/`delivery_days` |

### `02_product.sql`
| View | Grain | Ghi chú |
|---|---|---|
| `vw_category_segment` | category × price_segment | Heatmap; `pct_within_category` dùng `PARTITION BY category_en` |
| `vw_category_perf` | 1 category | Scatter 4 góc phần tư theo median `items_sold` × `avg_price` (Core/Mass/Premium/Underperform); `freight_share = SUM(freight_value)/SUM(item_revenue)` (không phải AVG từng dòng) |
| `vw_category_growth` | category × tháng, từ 2017-01 | MoM qua `LAG()`; chỉ giữ tháng có `orders >= 20` (tháng nhỏ % vô nghĩa) |

### `03_seller.sql`
| View | Grain | Ghi chú |
|---|---|---|
| `vw_seller_scorecard` | 1 seller, **chỉ seller >= 20 đơn** (783/3.095) | `segment`: Star/Risky/Emerging/Underperform theo median revenue + review>=4 + on_time>=90% |
| `vw_seller_concentration` | 1 seller, **toàn bộ 3.095 seller** | Lorenz curve: `pct_sellers_cumulative`, `pct_revenue_cumulative` |

Kết quả tập trung doanh thu (câu SQL độc lập cuối file): **top 10% seller
= 67,82% doanh thu, top 20% = 83,06%, 50% cuối chỉ 2,88%.**

### `04_delivery_customer.sql`
| View | Grain | Ghi chú |
|---|---|---|
| `vw_delivery_perf` | 1 tháng | on_time_rate/late_rate/avg_delivery_days/avg_delay_days, chỉ đơn delivered |
| `vw_delivery_distribution` | 5 nhóm ngày giao | `'0-7'/'8-14'/'15-21'/'22-30'/'30+'` + `sort_order` (tránh Superset sort alphabet sai) |
| `vw_delivery_route` | customer_state × seller_state, **>=30 đơn** (123/729 cặp) | Đọc từ `fct_order_items` để có cả 2 bang, join `fct_orders` lấy delivery/on_time |
| `vw_review_delay` | 6 nhóm độ trễ | Trễ >15 ngày → review rớt còn 1,72đ (75% bị 1-2 sao), sớm >7 ngày → 4,31đ |
| `vw_customer_summary` | Mua 1 lần / Mua lại | Chỉ 3,13% khách mua lại (khớp mô tả ~3,12%); `avg_orders_per_customer` nhóm "Mua 1 lần" = 1.0000 đúng như kỳ vọng |

### `05_data_quality.sql`
| View | Grain | Ghi chú |
|---|---|---|
| `vw_batch_summary` | 1 batch | Gộp 4 dòng/bảng của `ops.load_audit` thành 1 dòng; `quality_score = rows_loaded/rows_in*100` |
| `vw_reject_summary` | batch × source_table × reject_reason | Grain thực tế là bộ BA (không chỉ cặp) vì `reject_reason` bị tái dùng giữa các bảng |
| `vw_pipeline_health` | 1 dòng duy nhất | Viết dạng aggregate không `GROUP BY` để luôn ra đúng 1 dòng kể cả khi `ops.load_audit` rỗng |

**Tên cột/comment trong file này được viết trung tính theo yêu cầu** —
không diễn giải chênh lệch quality_score giữa các batch là xu hướng
"cải thiện dần", vì đó là do lỗi được chèn có chủ đích khác nhau mỗi
batch, không phải pipeline tốt lên.

## Việc chưa làm / cần lưu ý

- **Chưa có Airflow/orchestration thật** — toàn bộ 4 bước ETL phải gọi
  tay theo đúng thứ tự ở trên. Comment trong `02_stg_orders.sql` có nhắc
  "Airflow trigger" như thể sẽ có, nhưng chưa thấy DAG nào trong repo.
- **`batch_20180805`** đã có file CSV trong `data/batches/` nhưng chưa
  từng chạy qua `load_raw.sh` — nếu đây là batch kế tiếp cần nạp, dùng
  đúng chuỗi lệnh ở mục "Quy trình chạy pipeline".
- **`data/lan2/batch_20180804/`** — thư mục lạ, trùng tên batch với
  `data/batches/batch_20180804/` nhưng nằm ngoài `batches/`. Chưa rõ là
  bản nháp/thử lại hay dữ liệu cần dọn, chưa đụng vào, cần xác nhận.
