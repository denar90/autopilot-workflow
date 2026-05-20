.PHONY: test lint install

test:
	bats tests/

lint:
	shellcheck bin/autopilot lib/*.sh

install:
	./install.sh
