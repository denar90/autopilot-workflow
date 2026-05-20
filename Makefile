.PHONY: test lint install

test:
	bats tests/

lint:
	shellcheck -x --source-path=bin --source-path=lib bin/autopilot lib/*.sh

install:
	./install.sh
