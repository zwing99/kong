.PHONY: reset-db bench restart stop start


YAML=kong-default-single.yaml
reset-db:
	@cd .. && kong migrations reset -y > /dev/null || true
	@cd .. && kong migrations bootstrap > /dev/null
	@echo "database reset successfully"
	@cd .. && kong config db_import benchmark/$(YAML) > /dev/null
	@echo "import $(YAML) successfully"

ROUTER=traditional_compatible
restart:
	@cd .. && KONG_ROUTER_FLAVOR=$(ROUTER) KONG_NGINX_WORKER_PROCESSES=1 KONG_PROXY_ACCESS_LOG=off KONG_ANONYMOUS_REPORTS=off KONG_NGINX_EVENTS_WORKER_CONNECTIONS=65535 KONG_NGINX_MAIN_WORKER_RLIMIT_NOFILE=65535 kong restart
	@echo "kong started with ROUTER_FLAVOR =" `curl -s http://localhost:8001 | jq .configuration.router_flavor`
	@sleep 2

WARMUP_URL=http://localhost:8000
ROUTER=traditional_compatible
SCRIPT=
bench: reset-db restart
	@curl -s http://localhost:8001/status | jq ".memory.workers_lua_vms.[0]"
	$(eval PID := $(shell curl -s http://localhost:8001/status | jq ".memory.workers_lua_vms.[0].pid"))
	$(eval RSS := $(shell ps -o rss= -p $(PID)))
	@echo "PID($(PID)) RSS: `expr $(RSS) / 1024`m"
	@echo ""
	curl $(WARMUP_URL)
	@echo "\n"
	wrk -t12 -c500 -d10s --script $(SCRIPT) http://localhost:8000
	@cd .. && kong stop

stop:
	cd .. && kong stop

start:
	cd .. && kong start


# make demo YAML=kong-default-single.yaml ROUTER=traditional_compatible
# make demo YAML=kong-radix-single.yaml ROUTER=radix
demo: reset-db restart
	curl http://localhost:8000/users/100/profile-2023.pdf
