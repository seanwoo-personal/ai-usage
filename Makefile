.PHONY: docs test build check package hooks

docs:
	python3 -B scripts/check_docs.py
	python3 -B -m unittest discover -s scripts -p 'test_check_docs.py' -v

test:
	./scripts/selftest.sh

build:
	swift build

check: docs build test

package:
	./scripts/build-app.sh

hooks:
	git config core.hooksPath .githooks
