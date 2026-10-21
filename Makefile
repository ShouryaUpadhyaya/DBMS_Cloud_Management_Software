SHELL := /bin/bash
-include .env
export CRMS_APP_PASSWORD CRMS_COLLECTOR_PASSWORD CRMS_READONLY_PASSWORD DB_PORT

DC      := docker compose
DBEXEC  := $(DC) exec -T db
PSQL    := $(DBEXEC) psql -U postgres -d crms -v ON_ERROR_STOP=1
DB_URL  := postgres://crms_app:$${CRMS_APP_PASSWORD:-crms_app_dev}@127.0.0.1:$${DB_PORT:-55432}/crms

.PHONY: test-collector demo-alert reset up down clean migrate seed test test-sql test-race test-api test-web test-all demo-race demo-explain lint psql wait-db

up:            ## build and start the whole stack
	$(DC) up -d --build
	@$(MAKE) --no-print-directory wait-db

wait-db:
	@until $(DC) exec -T db pg_isready -U postgres -d crms >/dev/null 2>&1; do sleep 1; done

down:          ## stop the stack (keeps the data volume)
	$(DC) down

clean:         ## stop the stack and delete the data volume
	$(DC) down -v

migrate:       ## apply db/migrations in order
	$(DBEXEC) env CRMS_APP_PASSWORD=$${CRMS_APP_PASSWORD:-crms_app_dev} \
	  CRMS_COLLECTOR_PASSWORD=$${CRMS_COLLECTOR_PASSWORD:-crms_collector_dev} \
	  CRMS_READONLY_PASSWORD=$${CRMS_READONLY_PASSWORD:-crms_readonly_dev} \
	  bash /db/migrate.sh

seed:          ## load seed data (users, projects, pricing, 30 days of metrics)
	$(DBEXEC) bash /db/seed/seed.sh

test: test-sql test-race   ## database tests (constraints, triggers, procedures, RLS, race)

test-sql:
	$(DBEXEC) bash /db/tests/run.sh

test-race:
	$(DBEXEC) bash /db/tests/notify_test.sh
	$(DBEXEC) bash /db/tests/race_test.sh

test-api:
	cd api && npm ci --no-audit --no-fund && DATABASE_URL="$(DB_URL)" npm test

test-collector:
	cd collector && npm ci --no-audit --no-fund && npm test

test-web:
	cd web && npm ci --no-audit --no-fund && npm test && npm run build

test-all: test test-collector test-api test-web

demo-race:     ## two concurrent sessions: unsafe vs safe provisioning
	$(DBEXEC) bash /db/demo/run_race.sh

demo-alert:    ## fire a live CPU alert (watch the toast in the UI)
	$(PSQL) -f /db/demo/fire_alert.sql

demo-explain:  ## index effect on >=1M metric rows
	$(PSQL) -f /db/demo/explain_before_after.sql

lint:          ## typecheck api, web, collector
	cd api && npm run lint
	cd web && npm run lint
	cd collector && npm run lint

psql:
	$(DC) exec db psql -U postgres -d crms

reset:         ## wipe the database volume, then migrate and seed
	$(DC) down -v
	$(DC) up -d --build db
	@$(MAKE) --no-print-directory wait-db
	@$(MAKE) --no-print-directory migrate seed
