-- =====================================================================
-- TẦNG MART — đã join sẵn, Superset CHỈ đọc từ đây
-- Có 2 bảng fact ở 2 grain khác nhau để tránh nhân đôi số liệu:
--   fct_order_items : 1 dòng = 1 sản phẩm trong 1 đơn  -> doanh thu, sản phẩm, seller
--   fct_orders      : 1 dòng = 1 đơn                   -> thanh toán, review, giao hàng
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS mart;

-- ---------- Bảng fact chính, grain item ----------
DROP TABLE IF EXISTS mart.fct_order_items;
CREATE TABLE mart.fct_order_items (
    order_id                 VARCHAR(32)    NOT NULL,
    order_item_id            SMALLINT       NOT NULL,

    -- Khoá sang các chiều
    product_id               VARCHAR(32)    NOT NULL,
    seller_id                VARCHAR(32)    NOT NULL,
    customer_id              VARCHAR(32)    NOT NULL,
    customer_unique_id       VARCHAR(32)    NOT NULL,

    -- Thời gian
    order_purchase_timestamp TIMESTAMP      NOT NULL,
    order_purchase_date      DATE           NOT NULL,  -- tách sẵn để group by cho nhanh

    -- Tiền: doanh thu ở grain item = price + freight_value
    price                    NUMERIC(12, 2) NOT NULL,
    freight_value            NUMERIC(12, 2) NOT NULL,
    item_revenue             NUMERIC(12, 2) NOT NULL,

    -- Chiều dùng để filter trên dashboard
    order_status             VARCHAR(20)    NOT NULL,
    category_pt              VARCHAR(60)    NOT NULL,
    category_en              VARCHAR(60)    NOT NULL,  -- COALESCE, không bao giờ NULL
    customer_state           CHAR(2),
    customer_city            VARCHAR(60),
    seller_state             CHAR(2),
    seller_city              VARCHAR(60),

    -- Cột dẫn xuất phục vụ yêu cầu "phân khúc" của mentor
    price_segment            VARCHAR(12)    NOT NULL,  -- Binh dan / Trung cap / Cao cap
    is_cross_state           BOOLEAN        NOT NULL,  -- khách và seller khác bang
    freight_ratio            NUMERIC(6, 4),            -- phí ship / tổng giá

    batch_id                 TEXT           NOT NULL,
    loaded_at                TIMESTAMPTZ    NOT NULL DEFAULT NOW(),

    -- Khoá này là điều kiện để ON CONFLICT hoạt động, đã xác nhận 0 dòng trùng
    CONSTRAINT pk_fct_order_items PRIMARY KEY (order_id, order_item_id)
);

-- ---------- Bảng fact grain đơn hàng ----------
DROP TABLE IF EXISTS mart.fct_orders;
CREATE TABLE mart.fct_orders (
    order_id                      VARCHAR(32) PRIMARY KEY,
    customer_id                   VARCHAR(32) NOT NULL,
    customer_unique_id            VARCHAR(32) NOT NULL,
    order_status                  VARCHAR(20) NOT NULL,

    order_purchase_timestamp      TIMESTAMP   NOT NULL,
    order_purchase_date           DATE        NOT NULL,
    order_delivered_customer_date TIMESTAMP,
    order_estimated_delivery_date TIMESTAMP,

    -- Chỉ số giao hàng, CHỈ có nghĩa khi order_status = 'delivered'
    delivery_days                 SMALLINT,   -- số ngày từ lúc mua tới lúc nhận
    delay_days                    SMALLINT,   -- thực tế trừ dự kiến, âm là giao sớm
    is_late                       BOOLEAN,

    -- Tổng hợp từ order_items
    item_count                    SMALLINT    NOT NULL,
    order_revenue                 NUMERIC(12, 2) NOT NULL,

    -- Tổng hợp từ payments, gộp về 1 dòng cho khỏi nhân đôi
    payment_value                 NUMERIC(12, 2),
    payment_type_main             VARCHAR(20),  -- loại có giá trị lớn nhất
    max_installments              SMALLINT,

    -- Tổng hợp từ reviews, lấy review mới nhất nếu đơn có nhiều review
    review_score                  SMALLINT,

    -- Cờ phân biệt khách mua lần đầu hay mua lại
    is_repeat_customer            BOOLEAN     NOT NULL DEFAULT FALSE,

    batch_id                      TEXT        NOT NULL,
    loaded_at                     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ---------- Các bảng chiều ----------
DROP TABLE IF EXISTS mart.dim_product;
CREATE TABLE mart.dim_product (
    product_id       VARCHAR(32) PRIMARY KEY,
    category_pt      VARCHAR(60) NOT NULL,
    category_en      VARCHAR(60) NOT NULL,
    product_weight_g INTEGER,
    product_volume_cm3 INTEGER,   -- dài x rộng x cao, tính sẵn
    photos_qty       SMALLINT
);

DROP TABLE IF EXISTS mart.dim_seller;
CREATE TABLE mart.dim_seller (
    seller_id    VARCHAR(32) PRIMARY KEY,
    seller_city  VARCHAR(60),
    seller_state CHAR(2)
);

DROP TABLE IF EXISTS mart.dim_customer;
CREATE TABLE mart.dim_customer (
    customer_unique_id VARCHAR(32) PRIMARY KEY,
    customer_city      VARCHAR(60),
    customer_state     CHAR(2),
    first_order_date   DATE,
    total_orders       SMALLINT,
    total_spent        NUMERIC(12, 2)
);

-- Index cho các cột hay dùng làm filter trên dashboard
CREATE INDEX idx_fct_items_date     ON mart.fct_order_items (order_purchase_date);
CREATE INDEX idx_fct_items_cat      ON mart.fct_order_items (category_en);
CREATE INDEX idx_fct_items_seller   ON mart.fct_order_items (seller_id);
CREATE INDEX idx_fct_items_custstat ON mart.fct_order_items (customer_state);
CREATE INDEX idx_fct_items_segment  ON mart.fct_order_items (price_segment);
CREATE INDEX idx_fct_orders_date    ON mart.fct_orders (order_purchase_date);
CREATE INDEX idx_fct_orders_status  ON mart.fct_orders (order_status);