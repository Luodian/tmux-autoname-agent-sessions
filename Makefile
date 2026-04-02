.PHONY: lint

lint:
	bash -n scripts/*.sh
	python3 -m py_compile scripts/agent-history-data.py scripts/agent-scan.py
