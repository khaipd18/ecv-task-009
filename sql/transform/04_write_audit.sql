-- =====================================================================
-- GHI AUDIT CHO 1 BATCH VÀO ops.load_audit
-- Nhận biến :batch_id truyền từ dòng lệnh (psql -v batch_id=...).
-- Chạy SAU sql/transform/02_stg_orders.sql của batch đó, vì cần đọc
-- ops.rejected_rows và staging.* đã được ghi xong cho batch này.
--
-- Ghi 1 dòng / bảng đã xử lý (raw_orders, raw_order_items,
-- raw_order_payments, raw_order_reviews) -- đúng như ops.load_audit
-- được thiết kế "ghi riêng cho từng bảng" (xem sql/ddl/04_ops.sql).
--
-- Công thức mỗi số liệu:
--   rows_in       = COUNT(*) trong raw.<bảng>            WHERE batch_id = :batch_id
--   rows_rejected = COUNT(*) trong ops.rejected_rows      WHERE batch_id = :batch_id
--                   AND source_table = 'raw.<bảng>'
--   rows_loaded   = COUNT(*) trong staging.<bảng tương ứng> WHERE batch_id = :batch_id
--   rows_dup      = rows_in - rows_rejected - rows_loaded
--                   (phần còn lại sau khi trừ hết reject và loaded --
--                   đại diện cho dòng bị DISTINCT ON loại vì trùng
--                   NGAY TRONG batch, hoặc bị ON CONFLICT DO NOTHING
--                   loại vì trùng khoá với dữ liệu batch trước --
--                   không phải lỗi format nên không nằm trong
--                   ops.rejected_rows, nhưng cũng không vào được
--                   staging nên phải trừ ra).
-- =====================================================================

-- Xoá audit cũ của batch này trước khi ghi lại -- để file này CHẠY LẠI
-- ĐƯỢC nhiều lần (ví dụ Airflow retry) mà không cộng dồn/ghi trùng
-- dòng. Xoá theo batch_id, không phân biệt table_name, vì cả 4 dòng
-- của batch này đều phải được thay mới cùng lúc.
DELETE FROM ops.load_audit WHERE batch_id = :'batch_id';

-- ---------------------------------------------------------------------
-- raw_orders -> stg_orders
-- ---------------------------------------------------------------------
INSERT INTO ops.load_audit (batch_id, table_name, rows_in, rows_dup, rows_rejected, rows_loaded)
SELECT
    :'batch_id',
    'raw_orders',
    x.rows_in,
    x.rows_in - x.rows_rejected - x.rows_loaded AS rows_dup,
    x.rows_rejected,
    x.rows_loaded
FROM (
    SELECT
        (SELECT COUNT(*) FROM raw.raw_orders
          WHERE batch_id = :'batch_id')                              AS rows_in,
        (SELECT COUNT(*) FROM ops.rejected_rows
          WHERE batch_id = :'batch_id' AND source_table = 'raw.raw_orders') AS rows_rejected,
        (SELECT COUNT(*) FROM staging.stg_orders
          WHERE batch_id = :'batch_id')                              AS rows_loaded
) x;

-- ---------------------------------------------------------------------
-- raw_order_items -> stg_order_items
-- ---------------------------------------------------------------------
INSERT INTO ops.load_audit (batch_id, table_name, rows_in, rows_dup, rows_rejected, rows_loaded)
SELECT
    :'batch_id',
    'raw_order_items',
    x.rows_in,
    x.rows_in - x.rows_rejected - x.rows_loaded AS rows_dup,
    x.rows_rejected,
    x.rows_loaded
FROM (
    SELECT
        (SELECT COUNT(*) FROM raw.raw_order_items
          WHERE batch_id = :'batch_id')                                    AS rows_in,
        (SELECT COUNT(*) FROM ops.rejected_rows
          WHERE batch_id = :'batch_id' AND source_table = 'raw.raw_order_items') AS rows_rejected,
        (SELECT COUNT(*) FROM staging.stg_order_items
          WHERE batch_id = :'batch_id')                                    AS rows_loaded
) x;

-- ---------------------------------------------------------------------
-- raw_order_payments -> stg_order_payments
-- ---------------------------------------------------------------------
INSERT INTO ops.load_audit (batch_id, table_name, rows_in, rows_dup, rows_rejected, rows_loaded)
SELECT
    :'batch_id',
    'raw_order_payments',
    x.rows_in,
    x.rows_in - x.rows_rejected - x.rows_loaded AS rows_dup,
    x.rows_rejected,
    x.rows_loaded
FROM (
    SELECT
        (SELECT COUNT(*) FROM raw.raw_order_payments
          WHERE batch_id = :'batch_id')                                       AS rows_in,
        (SELECT COUNT(*) FROM ops.rejected_rows
          WHERE batch_id = :'batch_id' AND source_table = 'raw.raw_order_payments') AS rows_rejected,
        (SELECT COUNT(*) FROM staging.stg_order_payments
          WHERE batch_id = :'batch_id')                                       AS rows_loaded
) x;

-- ---------------------------------------------------------------------
-- raw_order_reviews -> stg_order_reviews
-- ---------------------------------------------------------------------
INSERT INTO ops.load_audit (batch_id, table_name, rows_in, rows_dup, rows_rejected, rows_loaded)
SELECT
    :'batch_id',
    'raw_order_reviews',
    x.rows_in,
    x.rows_in - x.rows_rejected - x.rows_loaded AS rows_dup,
    x.rows_rejected,
    x.rows_loaded
FROM (
    SELECT
        (SELECT COUNT(*) FROM raw.raw_order_reviews
          WHERE batch_id = :'batch_id')                                      AS rows_in,
        (SELECT COUNT(*) FROM ops.rejected_rows
          WHERE batch_id = :'batch_id' AND source_table = 'raw.raw_order_reviews') AS rows_rejected,
        (SELECT COUNT(*) FROM staging.stg_order_reviews
          WHERE batch_id = :'batch_id')                                      AS rows_loaded
) x;
