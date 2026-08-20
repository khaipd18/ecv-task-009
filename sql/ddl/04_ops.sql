-- =====================================================================
-- TẦNG OPS — nhật ký vận hành, đây là EVIDENCE mạnh nhất để trình mentor
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS ops;

-- Mỗi lần Airflow chạy ghi đúng 1 dòng vào đây
DROP TABLE IF EXISTS ops.load_audit;
CREATE TABLE ops.load_audit (
    audit_id       BIGSERIAL PRIMARY KEY,
    batch_id       TEXT        NOT NULL,
    table_name     TEXT        NOT NULL,   -- ghi riêng cho từng bảng
    run_time       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    rows_in        INTEGER     NOT NULL DEFAULT 0,  -- số dòng đọc từ file
    rows_dup       INTEGER     NOT NULL DEFAULT 0,  -- bị loại vì trùng
    rows_rejected  INTEGER     NOT NULL DEFAULT 0,  -- bị loại vì sai format
    rows_loaded    INTEGER     NOT NULL DEFAULT 0,  -- thực sự vào mart
    duration_sec   NUMERIC(8, 2),
    note           TEXT
);

-- Lưu lại từng dòng bị loại kèm lý do, để làm ảnh before/after cho slide
DROP TABLE IF EXISTS ops.rejected_rows;
CREATE TABLE ops.rejected_rows (
    reject_id    BIGSERIAL PRIMARY KEY,
    batch_id     TEXT        NOT NULL,
    source_table TEXT        NOT NULL,
    reject_reason TEXT       NOT NULL,   -- vd: 'timestamp sai format', 'price am'
    raw_payload  JSONB       NOT NULL,   -- toàn bộ dòng gốc, để đối chiếu
    rejected_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_audit_batch  ON ops.load_audit (batch_id);
CREATE INDEX idx_audit_time   ON ops.load_audit (run_time);
CREATE INDEX idx_reject_batch ON ops.rejected_rows (batch_id);