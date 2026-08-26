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

Cập nhật ngày 2026-08-24: đã làm sạch xong lỗi nạp trùng ở `raw`/`ops`
(xem mục "Kịch bản test từng batch" ở cuối file để biết chi tiết quy
trình làm sạch và số liệu sau khi sửa).

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

| batch_id | table_name | rows_in | rows_dup | rows_rejected | rows_loaded |
|---|---|---|---|---|---|
| 20180801 | raw_order_items | 347 | 0 | 0 | 347 |
| 20180801 | raw_order_payments | 331 | 0 | 0 | 331 |
| 20180801 | raw_order_reviews | 308 | 0 | 0 | 308 |
| 20180801 | raw_orders | 311 | 0 | 0 | 311 |
| 20180802 | raw_order_items | 383 | 47 | 0 | 336 |
| 20180802 | raw_order_payments | 360 | 54 | 0 | 306 |
| 20180802 | raw_order_reviews | 345 | 46 | 0 | 299 |
| 20180802 | raw_orders | 348 | 46 | 0 | 302 |
| 20180803 | raw_order_items | 347 | 4 | 23 | 320 |
| 20180803 | raw_order_payments | 326 | 4 | 13 | 309 |
| 20180803 | raw_order_reviews | 313 | 4 | 23 | 286 |
| 20180803 | raw_orders | 314 | 0 | 15 | 299 |
| 20180804 | raw_order_items | 323 | 42 | 24 | 257 |
| 20180804 | raw_order_payments | 298 | 43 | 12 | 243 |
| 20180804 | raw_order_reviews | 291 | 37 | 23 | 231 |
| 20180804 | raw_orders | 292 | 41 | 14 | 237 |
| seed | raw_order_items | 105401 | 0 | 0 | 105401 |
| seed | raw_order_payments | 97168 | 0 | 0 | 97168 |
| seed | raw_order_reviews | 92718 | 0 | 0 | 92718 |
| seed | raw_orders | 92909 | 0 | 0 | 92909 |

```sql
SELECT batch_id, table_name, rows_in, rows_dup, rows_rejected, rows_loaded
FROM ops.load_audit
ORDER BY batch_id, table_name;
```

## 11. `ops.rejected_rows` theo reject_reason

| reject_reason | Số dòng |
|---|---|
| orphan_row | 77 |
| invalid_timestamp | 29 |
| review_out_of_range | 16 |
| negative_price | 11 |
| missing_freight | 8 |
| price_not_numeric | 6 |

Tổng 147 dòng. Toàn bộ đã ra đúng mã tiếng Anh (đợt nạp trước khi đổi
mã đã bị xoá và nạp lại ở lần làm sạch 2026-08-24).

Lưu ý về `orphan_row`: mã này được gán khi dòng item/payment/review
không tìm thấy đơn cha trong `staging.stg_orders` TẠI THỜI ĐIỂM CHẠY.
Vì `staging.stg_orders` là bảng TÍCH LUỸ qua mọi batch (không reset
theo batch), số dòng `orphan_row` phụ thuộc vào việc các batch khác đã
nạp trước đó chưa — chạy lại `02_stg_orders.sql` cho 1 batch cũ SAU KHI
staging đã có sẵn dữ liệu từ batch khác có thể cho số `orphan_row` khác
với lần chạy đầu tiên (dòng trước đó "mồ côi" nay tìm thấy đơn cha).
Đây là đặc tính hợp lý của thiết kế pipeline, không phải lỗi.

```sql
SELECT reject_reason, COUNT(*) AS so_dong
FROM ops.rejected_rows
GROUP BY reject_reason
ORDER BY so_dong DESC;
```

---

## Kịch bản test từng batch

Mỗi batch ngày được `scripts/generate_batch.py` thiết kế với 1 vấn đề
khác nhau, để test riêng từng cơ chế xử lý của pipeline:

- **`batch_20180801`**: sạch hoàn toàn.
- **`batch_20180802`**: có ~15% dòng trùng với batch trước (test cơ chế
  `DISTINCT ON` + `ON CONFLICT DO NOTHING`).
- **`batch_20180803`**: có dữ liệu sai định dạng (timestamp, số âm,
  không phải số... — test cơ chế đẩy dòng lỗi sang `ops.rejected_rows`).
- **`batch_20180804` trở đi**: hỗn hợp cả hai (vừa trùng vừa sai định
  dạng — test pipeline xử lý đồng thời nhiều loại lỗi).

**Chênh lệch tỷ lệ lỗi giữa các batch là DO THIẾT KẾ TEST trong
`scripts/generate_batch.py`, KHÔNG PHẢI bằng chứng "pipeline cải thiện
theo thời gian"** — batch càng về sau không có nghĩa là dữ liệu càng
sạch hay bẩn hơn, chỉ là mỗi batch được cố ý nhồi một tổ hợp lỗi khác
nhau để chứng minh từng cơ chế hoạt động đúng.

Bảng đối chiếu `rows_dup`/`rows_rejected` thực tế của từng batch (gộp
cả 4 bảng/batch, lấy từ `ops.load_audit` SAU khi đã làm sạch lỗi nạp
trùng ngày 2026-08-24):

| batch_id | rows_in | rows_dup | rows_rejected | rows_loaded | quality_score |
|---|---|---|---|---|---|
| `20180801` | 1.297 | 0 | 0 | 1.297 | 100,00% |
| `20180802` | 1.436 | 193 | 0 | 1.243 | 86,56% |
| `20180803` | 1.300 | 12 | 74 | 1.214 | 93,38% |
| `20180804` | 1.204 | 163 | 73 | 968 | 80,40% |
| `seed` | 388.196 | 0 | 0 | 388.196 | 100,00% |

Khớp đúng kịch bản thiết kế: `20180801` không có `rows_dup` lẫn
`rows_rejected` (sạch hoàn toàn); `20180802` chỉ có `rows_dup` (193/1.436
≈ 13,4% — gần khớp mô tả "~15% trùng", chênh do làm tròn/khác nhau giữa
các bảng con); `20180803` chủ yếu là `rows_rejected` (lỗi định dạng);
`20180804` có cả hai. Lưu ý: tổng `rows_dup + rows_rejected` của
`20180803`/`20180804` (86 và 236) không đổi so với trước khi làm sạch —
chỉ riêng CÁCH PHÂN LOẠI dòng nào là "dup" hay "rejected" thay đổi nhẹ,
vì cơ chế phát hiện `orphan_row` phụ thuộc trạng thái tích luỹ của
`staging.stg_orders` tại thời điểm chạy (xem giải thích ở mục 10-11).

```sql
SELECT batch_id, rows_in, rows_dup, rows_rejected, rows_loaded, quality_score
FROM mart.vw_batch_summary
ORDER BY batch_id;
```
