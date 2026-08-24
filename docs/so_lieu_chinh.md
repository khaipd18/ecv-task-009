# Số liệu chính — dùng khi trình bày

Chạy trên container local `olist-dev` ngày 2026-08-24. Mỗi mục kèm câu SQL
đã dùng để chạy lại khi dữ liệu thay đổi (thêm batch mới, v.v).

## ⚠️ Đọc trước khi dùng

1. **Số trên máy local khác số trên stack tích hợp của đồng đội.** Local
   ở đây nạp tay 5 batch (`seed` + `20180801`...`20180804`). Stack tích
   hợp của Khải (Docker Compose + Airflow DAG, xem nhánh khác trong repo)
   chạy qua DAG, có thể đã nạp thêm/khác batch → số sẽ lệch. Muốn số
   khớp stack tích hợp, chạy lại đúng các câu SQL dưới đây nhưng nhắm
   vào container/DB của stack đó (đổi `docker exec -i olist-dev` thành
   tên container tương ứng).
2. **`ops.load_audit` và `ops.rejected_rows` local hiện đang SAI**, xem
   mục "⚠️ Vấn đề dữ liệu ops" ở cuối file — đừng dùng 2 bảng này để
   trình bày cho tới khi làm sạch lại. Mọi số liệu KINH DOANH (mục 1-9
   bên dưới) không bị ảnh hưởng, đã kiểm chứng riêng.

---

## 1. Tổng quan

| Chỉ số | Giá trị |
|---|---|
| Tổng doanh thu | **14.916.406,70** |
| Tổng số đơn (DISTINCT order_id, grain sản phẩm) | **92.898** |
| Tổng số dòng `fct_order_items` | **106.138** |

```sql
SELECT
  ROUND(SUM(item_revenue),2) AS tong_doanh_thu,
  COUNT(DISTINCT order_id)   AS tong_so_don,
  COUNT(*)                   AS tong_dong_fct_order_items
FROM mart.fct_order_items;
```

## 2. Khách / sản phẩm / seller

| Chỉ số | Giá trị |
|---|---|
| Số khách (`customer_unique_id`) | **89.857** |
| Số sản phẩm (`dim_product`) | **32.951** |
| Số seller (`dim_seller`) | **3.095** |

```sql
SELECT
  (SELECT COUNT(DISTINCT customer_unique_id) FROM mart.fct_order_items) AS so_khach,
  (SELECT COUNT(*) FROM mart.dim_product) AS so_san_pham,
  (SELECT COUNT(*) FROM mart.dim_seller)  AS so_seller;
```

## 3. Top 5 category theo doanh thu

| # | Category | Doanh thu | % tổng |
|---|---|---|---|
| 1 | health_beauty | 1.323.879,92 | 8,88% |
| 2 | watches_gifts | 1.234.740,52 | 8,28% |
| 3 | bed_bath_table | 1.176.753,38 | 7,89% |
| 4 | sports_leisure | 1.096.638,35 | 7,35% |
| 5 | computers_accessories | 1.013.169,33 | 6,79% |

Top 5 category cộng lại ≈ **39,19%** tổng doanh thu.

```sql
SELECT category_en, revenue, pct_of_total
FROM mart.vw_category_contribution
ORDER BY revenue DESC LIMIT 5;
```

## 4. Phân bố 3 phân khúc giá

| price_segment | Số lượng (dòng) | Doanh thu | % doanh thu |
|---|---|---|---|
| Premium | 21.450 | 7.854.632,95 | 52,66% |
| Mid-range | 47.999 | 5.371.600,96 | 36,01% |
| Budget | 36.689 | 1.690.172,79 | 11,33% |

Điểm đáng chú ý: Premium chỉ chiếm ~20% SỐ LƯỢNG sản phẩm bán ra nhưng
chiếm hơn **một nửa doanh thu**.

```sql
SELECT price_segment, COUNT(*) AS so_luong, ROUND(SUM(item_revenue),2) AS doanh_thu,
       ROUND(SUM(item_revenue)*100.0/SUM(SUM(item_revenue)) OVER(),2) AS pct_doanh_thu
FROM mart.fct_order_items
GROUP BY price_segment
ORDER BY doanh_thu DESC;
```

## 5. Mức độ tập trung doanh thu theo seller

| Nhóm | % doanh thu |
|---|---|
| Top 10% seller | **67,82%** |
| Top 20% seller | **83,06%** |
| 50% seller cuối | **2,88%** |

```sql
WITH moc_cat AS (
    SELECT
        MAX(pct_revenue_cumulative) FILTER (WHERE pct_sellers_cumulative <= 10) AS top10,
        MAX(pct_revenue_cumulative) FILTER (WHERE pct_sellers_cumulative <= 20) AS top20,
        MAX(pct_revenue_cumulative) FILTER (WHERE pct_sellers_cumulative <= 50) AS top50
    FROM mart.vw_seller_concentration
)
SELECT ROUND(top10,2) AS top10pct, ROUND(top20,2) AS top20pct, ROUND(100-top50,2) AS bottom50pct
FROM moc_cat;
```

## 6. Tỷ lệ giao đúng hạn (toàn bộ, không tách tháng)

| Chỉ số | Giá trị |
|---|---|
| Tổng đơn delivered | 91.250 |
| on_time_rate | **91,98%** |

```sql
SELECT
  COUNT(*) FILTER (WHERE order_status='delivered') AS tong_don_delivered,
  ROUND(
    COUNT(*) FILTER (WHERE order_status='delivered' AND is_late=FALSE)::NUMERIC
    / NULLIF(COUNT(*) FILTER (WHERE order_status='delivered' AND is_late IS NOT NULL),0) * 100
  ,2) AS on_time_rate_pct
FROM mart.fct_orders;
```

## 7. Thời gian giao trung bình: cross-state vs same-state

| Tuyến | Số đơn | avg_delivery_days |
|---|---|---|
| Same-state | 32.914 | **8,06 ngày** |
| Cross-state | 60.209 | **15,35 ngày** |

Đơn liên bang mất gần **gấp đôi** thời gian giao so với đơn nội bang.

```sql
WITH cap_bang_don AS (
    SELECT DISTINCT customer_state, seller_state, order_id,
           (customer_state IS DISTINCT FROM seller_state) AS is_cross_state
    FROM mart.fct_order_items
)
SELECT
    CASE WHEN is_cross_state THEN 'Cross-state' ELSE 'Same-state' END AS route_type,
    COUNT(DISTINCT cb.order_id) AS orders,
    ROUND(AVG(fo.delivery_days) FILTER (WHERE fo.order_status='delivered'),2) AS avg_delivery_days
FROM cap_bang_don cb
JOIN mart.fct_orders fo ON fo.order_id = cb.order_id
GROUP BY is_cross_state;
```

## 8. Điểm review trung bình theo nhóm độ trễ

| Nhóm | Số đơn | avg_review_score | % bị chấm 1-2 sao |
|---|---|---|---|
| 1. Early >7d | 69.020 | 4,31 | 8,97% |
| 2. Early 1-7d | 14.901 | 4,16 | 10,76% |
| 3. On time | 1.071 | 3,97 | 13,17% |
| 4. Late 1-7d | 3.422 | 2,67 | 49,62% |
| 5. Late 8-15d | 1.608 | 1,66 | 78,48% |
| 6. Late >15d | 1.220 | 1,72 | 75,49% |

```sql
SELECT delay_bucket, orders, avg_review_score, pct_score_1_2
FROM mart.vw_review_delay
ORDER BY sort_order;
```

## 9. Tỷ lệ khách mua lại

| Nhóm | Số khách | % |
|---|---|---|
| One-time | 87.070 | 96,87% |
| Repeat | 2.810 | **3,13%** |

```sql
SELECT customer_type, customers,
       ROUND(customers*100.0/SUM(customers) OVER(),2) AS pct_khach
FROM mart.vw_customer_summary;
```

---

## 10. `ops.load_audit` đầy đủ

```sql
SELECT batch_id, table_name, rows_in, rows_dup, rows_rejected, rows_loaded
FROM ops.load_audit
ORDER BY batch_id, table_name;
```

⚠️ **Xem cảnh báo ở cuối file trước khi dùng bảng này để trình bày** —
`rows_in`/`rows_dup` hiện đang bị thổi phồng do lỗi nạp trùng, xem chi
tiết bên dưới.

## 11. `ops.rejected_rows` theo reject_reason

```sql
SELECT reject_reason, COUNT(*) AS so_dong
FROM ops.rejected_rows
GROUP BY reject_reason
ORDER BY so_dong DESC;
```

⚠️ **Cũng bị ảnh hưởng bởi cùng lỗi nạp trùng** — xem bên dưới. Ngoài ra
các giá trị `reject_reason` hiện tại vẫn là chuỗi tiếng Việt cũ (dữ liệu
nạp trước khi đổi sang mã tiếng Anh ở commit `refactor(sql): chuan hoa
gia tri sang tieng Anh...`) — batch nạp SAU mới ra mã mới
(`invalid_timestamp`, `orphan_row`...).

---

## ⚠️ Vấn đề dữ liệu ops — cần làm sạch trước khi trình bày mục 10-11

**Phát hiện:** `raw.raw_orders` hiện có ĐÚNG GẤP ĐÔI số dòng mỗi batch so
với số `order_id` duy nhất (vd batch `seed`: 185.818 dòng nhưng chỉ
92.909 `order_id` distinct — tỷ lệ đúng 2,00). Xác nhận bằng:

```sql
SELECT batch_id, COUNT(*) AS so_dong, COUNT(DISTINCT order_id) AS distinct_order_id
FROM raw.raw_orders GROUP BY batch_id ORDER BY batch_id;
```

**Nguyên nhân:** ở phiên sửa `CASCADE` cho DDL, quy trình test đã nạp lại
toàn bộ 5 batch (`load_raw.sh` + `02_stg_orders.sql` + `04_write_audit.sql`
+ `03_mart_upsert.sql`) **HAI LẦN** (1 lần trước khi test CASCADE lần 2,
1 lần sau) — nhưng giữa 2 lần đó chỉ `sql/ddl/03_mart.sql` (schema mart)
được drop+tạo lại, KHÔNG drop `sql/ddl/01_raw.sql` hay `sql/ddl/04_ops.sql`.
Kết quả: mỗi dòng CSV bị `\copy` vào `raw.*` hai lần, và bước phát hiện
lỗi trong `02_stg_orders.sql` (insert vào `ops.rejected_rows`) cũng chạy
hai lần trên cùng dữ liệu chưa được dedupe ở tầng raw.

**KHÔNG ảnh hưởng số liệu kinh doanh** — đã xác minh riêng:
- `staging.stg_orders` = 94.058 dòng, đúng bằng tổng cộng dồn qua 5 batch
  (nhờ `DISTINCT ON` + `ON CONFLICT DO NOTHING` khử trùng đúng ở bước
  raw→staging).
- `SUM(item_revenue)` từ `mart.fct_order_items` vẫn = 14.916.406,70,
  khớp với mọi lần kiểm tra trước đó.

**Cách làm sạch (chưa thực hiện — cần làm ở cửa sổ bảo trì, KHÔNG làm
giữa lúc đồng đội đang deploy vì đây là thao tác `DROP TABLE CASCADE`
trên container dùng chung):**

```bash
# 1. Rebuild lại raw + ops (xoá sạch dữ liệu 2 schema này)
docker exec -i olist-dev psql -U postgres -d olist -v ON_ERROR_STOP=1 -q < sql/ddl/01_raw.sql
docker exec -i olist-dev psql -U postgres -d olist -v ON_ERROR_STOP=1 -q < sql/ddl/04_ops.sql

# 2. Nạp lại đúng 1 LẦN cho từng batch (seed trước, rồi 4 batch ngày)
docker exec -u postgres -i olist-dev bash -s -- /data/batches/seed seed < scripts/load_raw.sh
docker exec -i olist-dev psql -U postgres -d olist -v batch_id=seed -v ON_ERROR_STOP=1 -q < sql/transform/01_stg_static.sql
docker exec -i olist-dev psql -U postgres -d olist -v batch_id=seed -v ON_ERROR_STOP=1 -q < sql/transform/02_stg_orders.sql
docker exec -i olist-dev psql -U postgres -d olist -v batch_id=seed -v ON_ERROR_STOP=1 -q < sql/transform/04_write_audit.sql
# ... lặp lại cho 20180801..20180804 (không có 01_stg_static.sql, chỉ 1 lần cho seed)

# 3. Nạp lại mart từ staging (không đổi vì staging vốn đã sạch)
docker exec -i olist-dev psql -U postgres -d olist -v ON_ERROR_STOP=1 -q < sql/transform/03_mart_upsert.sql

# 4. Tạo lại view
for f in sql/marts/*.sql; do
  docker exec -i olist-dev psql -U postgres -d olist -v ON_ERROR_STOP=1 -q < "$f"
done
```

Sau khi làm sạch, chạy lại 2 câu SQL ở mục 10-11 để có số đúng, rồi thay
vào file này.
