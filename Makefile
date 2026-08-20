# ============================================================================
# Lệnh tắt. Lúc demo gõ `make up` nhìn gọn hơn và ít gõ sai hơn.
# ============================================================================
SHELL := /bin/bash
include .env
export

.PHONY: help init up down restart reset truncate-data logs ps psql ddl views dag-list dag-test dag-trigger dag-unpause evidence build tailscale-info dashboard-export dashboard-import

help:            ## Xem danh sách lệnh
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n",$$1,$$2}'

init:            ## Chuẩn bị thư mục + quyền (CHẠY 1 LẦN trước khi up)
	mkdir -p logs plugins data/raw data/batches data/state docs/evidence
	touch data/raw/.gitkeep data/batches/.gitkeep data/state/.gitkeep
	sudo chown -R $$(id -u):0 logs plugins data
	@echo "AIRFLOW_UID nen dat = $$(id -u) trong file .env"

build:           ## Build image Airflow
	docker compose build

up:              ## Khởi động toàn bộ stack
	docker compose up -d
	@echo "Airflow  -> http://localhost:$(AIRFLOW_HOST_PORT)"
	@echo "Superset -> http://localhost:$(SUPERSET_HOST_PORT)"

down:            ## Dừng stack (GIỮ dữ liệu)
	docker compose down

reset:           ## [NGUY HIEM] Xoa sach volume - MAT dashboard cua Noel va lich su DagRun
	@echo ""
	@echo "  ==============================================================="
	@echo "   CANH BAO: lenh nay xoa CA 3 DATABASE."
	@echo "   -> Mat toan bo chart/dashboard Noel da dung (DB superset)"
	@echo "   -> Mat lich su DagRun, tuc la mat EVIDENCE (DB airflow)"
	@echo ""
	@echo "   Muon lam sach du lieu nghiep vu thi dung:  make truncate-data"
	@echo "   Chi dung 'make reset' khi sua init script Postgres."
	@echo "   PHAI BAO NOEL TRUOC."
	@echo "  ==============================================================="
	@echo ""
	@read -p "  Go 'xoa het' de xac nhan: " x; [ "$$x" = "xoa het" ] || (echo "  Da huy."; exit 1)
	docker compose down -v
	rm -f data/batches/*.csv data/state/*.json
	@echo "Da xoa sach. Chay 'make up' de dung lai tu dau."

truncate-data:   ## Lam sach du lieu nghiep vu, GIU dashboard + lich su DagRun
	docker compose exec -T postgres psql -U $(APP_DB_USER) -d $(APP_DB) -c \
	  "TRUNCATE raw.raw_orders, raw.raw_order_items, raw.raw_order_payments, raw.raw_order_reviews, staging.stg_orders, staging.stg_order_items, staging.stg_order_payments, staging.stg_order_reviews, mart.fct_order_items, ops.rejected_rows RESTART IDENTITY CASCADE;"
	rm -f data/batches/*.csv data/state/*.json
	@echo "Da truncate bang DONG + fct. GIU nguyen bang TINH (products/customers/sellers), ops.load_audit va dashboard."
	@echo "Muon xoa ca lich su audit thi them: TRUNCATE ops.load_audit;"

restart:         ## Khởi động lại
	docker compose restart

ps:              ## Trạng thái các service
	docker compose ps

logs:            ## Xem log (make logs s=airflow-scheduler)
	docker compose logs -f $(s)

psql:            ## Vào psql của DB nghiệp vụ
	docker compose exec postgres psql -U $(APP_DB_USER) -d $(APP_DB)

dag-list:        ## Liệt kê DAG
	docker compose exec airflow-scheduler airflow dags list

dag-test:        ## Chạy thử toàn bộ DAG không cần scheduler
	docker compose exec airflow-scheduler airflow dags test olist_daily_pipeline $$(date +%Y-%m-%d)

dag-unpause:     ## Bật schedule
	docker compose exec airflow-scheduler airflow dags unpause olist_daily_pipeline

dag-trigger:     ## Trigger 1 run thủ công (dùng khi demo)
	docker compose exec airflow-scheduler airflow dags trigger olist_daily_pipeline

evidence:        ## Thu thập evidence sau mỗi run
	./scripts/capture_evidence.sh

tailscale-info:  ## In endpoint de gui cho Noel
	@echo "Tailscale IP: $$(tailscale ip -4 2>/dev/null || echo 'CHUA CAI - xem sheet Truy cap chung')"
	@IP=$$(tailscale ip -4 2>/dev/null | head -1); \
	 echo "  Airflow  : http://$$IP:$(AIRFLOW_HOST_PORT)"; \
	 echo "  Superset : http://$$IP:$(SUPERSET_HOST_PORT)"; \
	 echo "  Postgres : $$IP:$(POSTGRES_HOST_PORT)  (db=$(APP_DB), user=$(APP_DB_USER))"

dashboard-export: ## Backup dashboard Superset ra file zip (Noel chay moi cuoi buoi)
	docker compose exec superset superset export-dashboards -f /app/dashboard_export.zip
	docker compose cp superset:/app/dashboard_export.zip ./superset/dashboard_export.zip
	@echo "Da luu ./superset/dashboard_export.zip — nho git add + commit."

dashboard-import: ## Khoi phuc dashboard tu file zip
	docker compose cp ./superset/dashboard_export.zip superset:/app/d.zip
	docker compose exec superset superset import-dashboards -p /app/d.zip -u $(SUPERSET_ADMIN_USER)
	@echo "Luu y: file export KHONG chua mat khau DB, Superset se hoi lai."

ddl:             ## [XAY LAI SCHEMA] Chay sql/ddl/ bang olist_user - DROP+CREATE bang, MAT du lieu nghiep vu
	@echo ">> Chay sql/ddl/*.sql (DROP+CREATE bang olist). Huy trong 3s neu nham..."; sleep 3
	@for f in 01_raw 02_staging 03_mart 04_ops; do \
	  echo "-- ddl/$$f.sql"; \
	  docker compose exec -T -e PGPASSWORD=$(APP_DB_PASSWORD) airflow-scheduler \
	    psql -h postgres -U $(APP_DB_USER) -d $(APP_DB) -v ON_ERROR_STOP=1 \
	    -f /opt/airflow/sql/ddl/$$f.sql >/dev/null || exit 1; \
	done
	@echo ">> DDL xong: raw/staging/mart/ops da tao lai. Gio chay 'make seed'."

views:           ## Tao/cap nhat view Superset (sql/marts/) - CREATE OR REPLACE, an toan chay lai
	@for f in 01_overview 02_product 03_seller 04_delivery_customer 05_data_quality; do \
	  echo "-- marts/$$f.sql"; \
	  docker compose exec -T -e PGPASSWORD=$(APP_DB_PASSWORD) airflow-scheduler \
	    psql -h postgres -U $(APP_DB_USER) -d $(APP_DB) -v ON_ERROR_STOP=1 \
	    -f /opt/airflow/sql/marts/$$f.sql >/dev/null || exit 1; \
	done
	@echo ">> Views xong: Superset doc duoc mart.vw_* (superset_ro tu co quyen)."

seed:            ## Seed bang tinh + batch nen - CHAY 1 LAN truoc khi bat schedule (can 'make ddl' truoc)
	docker compose exec airflow-scheduler airflow dags trigger olist_seed_static
	@echo "Theo doi tren UI, doi tat ca task xanh roi moi chay 'make dag-unpause'."

check-seed:      ## Kiem tra dimension da co du lieu chua
	docker compose exec -T postgres psql -U $(APP_DB_USER) -d $(APP_DB) -c \
	  "SELECT 'dim_product' t, COUNT(*) FROM mart.dim_product \
	   UNION ALL SELECT 'dim_customer', COUNT(*) FROM mart.dim_customer \
	   UNION ALL SELECT 'dim_seller', COUNT(*) FROM mart.dim_seller;"

set-vars:        ## Nap credential Postgres vao Airflow Variable cho load_raw.sh (chay 1 lan sau khi up)
	docker compose exec -T airflow-scheduler airflow variables set olist_db "$(APP_DB)"
	docker compose exec -T airflow-scheduler airflow variables set olist_user "$(APP_DB_USER)"
	docker compose exec -T airflow-scheduler airflow variables set olist_password "$(APP_DB_PASSWORD)"
	@echo "Da nap 3 bien. Kiem tra: docker compose exec airflow-scheduler airflow variables list"

batches:         ## Xem batch nao da nap, batch nao con lai
	@echo "--- Thu muc co san ---"
	@ls -1 data/batches 2>/dev/null || echo "(trong)"
	@echo "--- Da nap (theo ops.load_audit) ---"
	@docker compose exec -T postgres psql -U $(APP_DB_USER) -d $(APP_DB) -tAc \
	  "SELECT DISTINCT batch_id FROM ops.load_audit ORDER BY 1;" 2>/dev/null || echo "(chua co)"
