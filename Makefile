# Local verification targets.
# TMPDIR must point at disk-backed storage: sqflite writes to /tmp, which is a
# tmpfs here, and fills it mid-suite (disk I/O error 778).
TMPDIR ?= /home/barry/.cache/flutter-tmp

.PHONY: test analyze format check

test:
	mkdir -p $(TMPDIR)
	TMPDIR=$(TMPDIR) flutter test --no-pub

analyze:
	flutter analyze

format:
	dart format --output=none --set-exit-if-changed lib test tool

check: format analyze test
