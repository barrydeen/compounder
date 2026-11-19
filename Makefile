# Local verification targets.
# TMPDIR must point at disk-backed storage: sqflite writes to /tmp, which is a
# tmpfs here, and fills it mid-suite (disk I/O error 778).
TMPDIR ?= /home/barry/.cache/flutter-tmp

# package:test defaults to one worker per core (32 here), so a bare
# `flutter test` spawns 32 flutter_tester VMs at once. They exhaust RAM and get
# pushed into zram swap, and the suite takes minutes instead of seconds — the
# tests themselves are fine (~20 s total on this box at 6 workers).
JOBS ?= 6

.PHONY: test analyze format check

test:
	mkdir -p $(TMPDIR)
	TMPDIR=$(TMPDIR) flutter test --no-pub --concurrency=$(JOBS)

analyze:
	flutter analyze

format:
	dart format --output=none --set-exit-if-changed lib test tool

check: format analyze test
