-- =====================================================================
-- TẦNG RAW — nhận dữ liệu thô, KHÔNG ép kiểu, KHÔNG làm sạch
-- Mọi cột để TEXT để dòng bẩn vẫn nạp được mà không làm fail cả batch
-- Đây là bằng chứng "dữ liệu bẩn có thật" khi trình bày với mentor
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS raw;

-- ---------- Bảng động: nạp thêm mỗi lần Airflow chạy ----------

DROP TABLE IF EXISTS raw.raw_orders CASCADE;
CREATE TABLE raw.raw_orders (
    order_id                        TEXT,
    customer_id                     TEXT,
    order_status                    TEXT,
    order_purchase_timestamp        TEXT,
    order_approved_at               TEXT,
    order_delivered_carrier_date    TEXT,
    order_delivered_customer_date   TEXT,
    order_estimated_delivery_date   TEXT,
    -- 2 cột kỹ thuật do pipeline thêm vào, không có trong file gốc
    batch_id                        TEXT        NOT NULL,
    ingested_at                     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

DROP TABLE IF EXISTS raw.raw_order_items CASCADE;
CREATE TABLE raw.raw_order_items (
    order_id            TEXT,
    order_item_id       TEXT,   -- gốc là int nhưng để TEXT phòng dòng bẩn
    product_id          TEXT,
    seller_id           TEXT,
    shipping_limit_date TEXT,
    price               TEXT,
    freight_value       TEXT,
    batch_id            TEXT        NOT NULL,
    ingested_at         TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

DROP TABLE IF EXISTS raw.raw_order_payments CASCADE;
CREATE TABLE raw.raw_order_payments (
    order_id             TEXT,
    payment_sequential   TEXT,
    payment_type         TEXT,
    payment_installments TEXT,
    payment_value        TEXT,
    batch_id             TEXT        NOT NULL,
    ingested_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

DROP TABLE IF EXISTS raw.raw_order_reviews CASCADE;
CREATE TABLE raw.raw_order_reviews (
    review_id               TEXT,
    order_id                TEXT,
    review_score            TEXT,
    review_comment_title    TEXT,
    review_comment_message  TEXT,   -- có xuống dòng và dấu phẩy, cẩn thận khi COPY
    review_creation_date    TEXT,
    review_answer_timestamp TEXT,
    batch_id                TEXT        NOT NULL,
    ingested_at             TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ---------- Bảng tĩnh: chỉ nạp MỘT LẦN lúc seed ----------

DROP TABLE IF EXISTS raw.raw_products CASCADE;
CREATE TABLE raw.raw_products (
    product_id                  TEXT,
    product_category_name       TEXT,
    product_name_lenght         TEXT,   -- sai chính tả là của file gốc, giữ nguyên
    product_description_lenght  TEXT,
    product_photos_qty          TEXT,
    product_weight_g            TEXT,
    product_length_cm           TEXT,
    product_height_cm           TEXT,
    product_width_cm            TEXT,
    batch_id                    TEXT        NOT NULL DEFAULT 'seed',
    ingested_at                 TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

DROP TABLE IF EXISTS raw.raw_customers CASCADE;
CREATE TABLE raw.raw_customers (
    customer_id              TEXT,
    customer_unique_id       TEXT,
    customer_zip_code_prefix TEXT,
    customer_city            TEXT,
    customer_state           TEXT,
    batch_id                 TEXT        NOT NULL DEFAULT 'seed',
    ingested_at              TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

DROP TABLE IF EXISTS raw.raw_sellers CASCADE;
CREATE TABLE raw.raw_sellers (
    seller_id              TEXT,
    seller_zip_code_prefix TEXT,
    seller_city            TEXT,
    seller_state           TEXT,
    batch_id               TEXT        NOT NULL DEFAULT 'seed',
    ingested_at            TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

DROP TABLE IF EXISTS raw.raw_category_translation CASCADE;
CREATE TABLE raw.raw_category_translation (
    product_category_name         TEXT,
    product_category_name_english TEXT,
    batch_id                      TEXT        NOT NULL DEFAULT 'seed',
    ingested_at                   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Index phục vụ bước transform, đặt trên cột dùng để lọc theo batch
CREATE INDEX idx_raw_orders_batch  ON raw.raw_orders (batch_id);
CREATE INDEX idx_raw_items_batch   ON raw.raw_order_items (batch_id);
CREATE INDEX idx_raw_pay_batch     ON raw.raw_order_payments (batch_id);
CREATE INDEX idx_raw_rev_batch     ON raw.raw_order_reviews (batch_id);