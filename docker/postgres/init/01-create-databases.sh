#!/bin/bash
# ============================================================================
# Chạy TỰ ĐỘNG khi container postgres khởi tạo LẦN ĐẦU (volume còn rỗng).
#
# QUAN TRỌNG: sửa file này xong phải `docker compose down -v` rồi `up -d` lại,
# nếu không script sẽ KHÔNG chạy lại và bạn sẽ ngồi debug oan.
#
# Nhớ: chmod +x file này, line ending phải là LF (đã có .gitattributes lo).
# ============================================================================
set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres <<-EOSQL
    -- ===== 3 database dùng chung 1 instance cho nhẹ RAM =====
    CREATE DATABASE ${AIRFLOW_DB};
    CREATE DATABASE ${SUPERSET_DB};
    CREATE DATABASE ${APP_DB};

    -- ===== User ghi dữ liệu (Airflow dùng) =====
    CREATE USER ${APP_DB_USER} WITH PASSWORD '${APP_DB_PASSWORD}';
    GRANT ALL PRIVILEGES ON DATABASE ${APP_DB} TO ${APP_DB_USER};

    -- ===== User read-only (Superset dùng) =====
    CREATE USER ${SUPERSET_RO_USER} WITH PASSWORD '${SUPERSET_RO_PASSWORD}';
    GRANT CONNECT ON DATABASE ${APP_DB} TO ${SUPERSET_RO_USER};
EOSQL

# ===== Tạo schema 3 tầng + phân quyền, chạy TRONG database nghiệp vụ =====
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "${APP_DB}" <<-EOSQL
    CREATE SCHEMA IF NOT EXISTS raw     AUTHORIZATION ${APP_DB_USER};
    CREATE SCHEMA IF NOT EXISTS staging AUTHORIZATION ${APP_DB_USER};
    CREATE SCHEMA IF NOT EXISTS mart    AUTHORIZATION ${APP_DB_USER};
    CREATE SCHEMA IF NOT EXISTS ops     AUTHORIZATION ${APP_DB_USER};

    -- Superset chỉ được đọc mart + ops (không cho đụng raw/staging)
    GRANT USAGE ON SCHEMA mart, ops TO ${SUPERSET_RO_USER};
    GRANT SELECT ON ALL TABLES IN SCHEMA mart, ops TO ${SUPERSET_RO_USER};

    -- Bảng Noel tạo SAU này cũng tự động được cấp quyền đọc.
    -- Không có dòng này thì mỗi lần tạo bảng mới lại phải GRANT tay.
    ALTER DEFAULT PRIVILEGES FOR ROLE ${APP_DB_USER} IN SCHEMA mart, ops
        GRANT SELECT ON TABLES TO ${SUPERSET_RO_USER};
EOSQL

echo "[init] Da tao ${AIRFLOW_DB}, ${SUPERSET_DB}, ${APP_DB} + schema raw/staging/mart/ops"
