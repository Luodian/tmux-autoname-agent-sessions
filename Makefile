.PHONY: lint

lint:
	bash -n scripts/agent-rename.sh
	bash -n tmux-autoname-agent-sessions.tmux
