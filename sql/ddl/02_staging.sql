-- =====================================================================
-- TẦNG STAGING — đã ép kiểu, đã làm sạch, chưa join
-- Dòng nào ép kiểu lỗi thì bị đẩy sang ops.rejected_rows kèm lý do
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS staging;

DROP TABLE IF EXISTS staging.stg_orders;
CREATE TABLE staging.stg_orders (
    order_id                        VARCHAR(32) PRIMARY KEY,
    customer_id                     VARCHAR(32) NOT NULL,
    order_status                    VARCHAR(20) NOT NULL,
    order_purchase_timestamp        TIMESTAMP   NOT NULL,
    order_approved_at               TIMESTAMP,
    order_delivered_carrier_date    TIMESTAMP,
    order_delivered_customer_date   TIMESTAMP,
    order_estimated_delivery_date   TIMESTAMP,
    batch_id                        TEXT        NOT NULL,
    ingested_at                     TIMESTAMPTZ NOT NULL
);

DROP TABLE IF EXISTS staging.stg_order_items;
CREATE TABLE staging.stg_order_items (
    order_id            VARCHAR(32)    NOT NULL,
    order_item_id       SMALLINT       NOT NULL,
    product_id          VARCHAR(32)    NOT NULL,
    seller_id           VARCHAR(32)    NOT NULL,
    shipping_limit_date TIMESTAMP,
    price               NUMERIC(12, 2) NOT NULL CHECK (price >= 0),
    freight_value       NUMERIC(12, 2) NOT NULL CHECK (freight_value >= 0),
    batch_id            TEXT           NOT NULL,
    ingested_at         TIMESTAMPTZ    NOT NULL,
    PRIMARY KEY (order_id, order_item_id)
);

-- Payments ở grain ĐƠN HÀNG, một đơn có thể nhiều dòng (trả góp, nhiều thẻ)
-- Không được join thẳng vào item, sẽ nhân đôi doanh thu
DROP TABLE IF EXISTS staging.stg_order_payments;
CREATE TABLE staging.stg_order_payments (
    order_id             VARCHAR(32)    NOT NULL,
    payment_sequential   SMALLINT       NOT NULL,
    payment_type         VARCHAR(20)    NOT NULL,
    payment_installments SMALLINT       NOT NULL,
    payment_value        NUMERIC(12, 2) NOT NULL CHECK (payment_value >= 0),
    batch_id             TEXT           NOT NULL,
    ingested_at          TIMESTAMPTZ    NOT NULL,
    PRIMARY KEY (order_id, payment_sequential)
);

-- Lưu ý: review_id trong Olist KHÔNG duy nhất tuyệt đối,
-- nên khoá phải là cặp (review_id, order_id)
DROP TABLE IF EXISTS staging.stg_order_reviews;
CREATE TABLE staging.stg_order_reviews (
    review_id               VARCHAR(32) NOT NULL,
    order_id                VARCHAR(32) NOT NULL,
    review_score            SMALLINT    NOT NULL CHECK (review_score BETWEEN 1 AND 5),
    review_comment_title    TEXT,
    review_comment_message  TEXT,
    review_creation_date    TIMESTAMP,
    review_answer_timestamp TIMESTAMP,
    batch_id                TEXT        NOT NULL,
    ingested_at             TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (review_id, order_id)
);

DROP TABLE IF EXISTS staging.stg_products;
CREATE TABLE staging.stg_products (
    product_id                 VARCHAR(32) PRIMARY KEY,
    product_category_name      VARCHAR(60) NOT NULL,  -- đã COALESCE, không còn NULL
    product_name_lenght        SMALLINT,
    product_description_lenght INTEGER,
    product_photos_qty         SMALLINT,
    product_weight_g           INTEGER,
    product_length_cm          SMALLINT,
    product_height_cm          SMALLINT,
    product_width_cm           SMALLINT,
    batch_id                   TEXT        NOT NULL,
    ingested_at                TIMESTAMPTZ NOT NULL
);

DROP TABLE IF EXISTS staging.stg_customers;
CREATE TABLE staging.stg_customers (
    customer_id              VARCHAR(32) PRIMARY KEY,
    customer_unique_id       VARCHAR(32) NOT NULL,  -- ĐÂY mới là khách thật
    customer_zip_code_prefix VARCHAR(8),
    customer_city            VARCHAR(60),
    customer_state           CHAR(2),
    batch_id                 TEXT        NOT NULL,
    ingested_at              TIMESTAMPTZ NOT NULL
);

DROP TABLE IF EXISTS staging.stg_sellers;
CREATE TABLE staging.stg_sellers (
    seller_id              VARCHAR(32) PRIMARY KEY,
    seller_zip_code_prefix VARCHAR(8),
    seller_city            VARCHAR(60),
    seller_state           CHAR(2),
    batch_id               TEXT        NOT NULL,
    ingested_at            TIMESTAMPTZ NOT NULL
);

DROP TABLE IF EXISTS staging.stg_category_translation;
CREATE TABLE staging.stg_category_translation (
    product_category_name         VARCHAR(60) PRIMARY KEY,
    product_category_name_english VARCHAR(60) NOT NULL
);

CREATE INDEX idx_stg_orders_purchase ON staging.stg_orders (order_purchase_timestamp);
CREATE INDEX idx_stg_orders_status   ON staging.stg_orders (order_status);
CREATE INDEX idx_stg_items_product   ON staging.stg_order_items (product_id);
CREATE INDEX idx_stg_items_seller    ON staging.stg_order_items (seller_id);