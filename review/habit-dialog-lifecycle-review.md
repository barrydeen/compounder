# Habit-create dialog controller lifecycle fix — gate

- **Repo/commit:** `compounder` `0e69cee` ("fix(ui): own dialog controllers in State so teardown cannot outlive the route", 3 files: `lib/ui/habits.dart`, `lib/ui/mind.dart`, `test/dialog_controller_lifecycle_test.dart`).
- **Base:** `b79dc43` (main).
- **Date:** 2026-11-11
- **Mode:** read-only adversarial gate. No source files modified by me. All probes/reverts were done in a pinned worktree (`/home/barry/.cache/review-wt/habit-dialog-gate`, detached at `0e69cee`), restored afterwards; worktree clean (`git status --porcelain` empty) at the reviewed commit.

## Verdict

**APPROVE WITH FIXES** — the fix is correct, minimal, and the regression guard is genuinely non-vacuous (revert failures quoted below). One **Major** finding: the new test file fails the repo's own format gate (`dart format --set-exit-if-changed`), so CI's `format` job will fail on this commit as-is. Trivial fix (reformat 3 lines in the test file); no source-code change needed.

## Gates (all run by me in the pinned worktree at `0e69cee`, Flutter 3.47.4 = CI's pinned `FLUTTER_VERSION`)

| Command | Result |
|---|---|
| `flutter pub get` | ok |
| `dart format --output=none --set-exit-if-changed lib test tool` | **FAIL** — `Formatted 102 files (1 changed)`, the one changed file is `test/dialog_controller_lifecycle_test.dart` (see Major m1). Parent `b79dc43` passes the same command (`101 files (0 changed)`), so this commit introduces the regression. |
| `flutter analyze` | `No issues found! (ran in 3.6s)` |
| `flutter test` (full suite) | `00:28 +613: All tests passed!` |
| `flutter test test/dialog_controller_lifecycle_test.dart` | `00:01 +3: All tests passed!` |

## Per-item verdicts

| # | Requirement | Verdict |
|---|---|---|
| 1 | Controllers owned/disposed by a StatefulWidget dialog State, not disposed after `await showDialog` | **PASS.** `_editHabit` (`lib/ui/habits.dart:236`) now only does `await showDialog(builder: (context) => _HabitDialog(store: store, habit: habit))` — no caller-side controllers, no post-await `dispose()`. `_HabitDialogState` creates both controllers in `initState` (`:257-262`) and disposes both in `dispose()` (`:264-268`). Same for `_ThoughtDialog`/`_ThoughtDialogState` (`lib/ui/mind.dart:297-313`): three controllers created as State fields, all three disposed in `dispose()`. The old caller-side `name.dispose(); target.dispose();` after `await showDialog` is gone. |
| 2 | No leak introduced | **PASS.** Each controller is created exactly once per dialog instance and disposed exactly once in the owning State's `dispose()`, which the framework runs when the route is unmounted — the same pattern `_DescribeMealSheet`/`_MealEditSheet` already use. The `Habit` model is a plain immutable class (not a `ChangeNotifier`, `lib/data/models.dart:462`), so holding `widget.habit` adds no listener; the dialog State never calls `store.addListener`, so the `store` reference adds no listener either. No timers/listeners/streams in either State. |
| 3 | Inline validation and store write-boundary behaviour unchanged | **PASS.** Line-by-line comparison of old vs new `_save`: same `int.tryParse(target.text.trim())`, same two inline checks with identical messages (`'Enter a habit name.'`, `'Target must be a whole number of at least 1.'`), same `await store.createHabit(name.text, cadence.name, days)` / `store.updateHabit(habit.id, name:…, cadence:…, target:…)` calls, same `if (mounted) Navigator.pop(context)` after a successful write, same `on StoreException` → `if (mounted) setState(() => error = e.message)`. The store's re-validation write boundary (`createHabit`/`updateHabit` in `lib/data/store.dart:1348/1375`) is untouched — the commit touches only the two UI files and the new test. B3 enable-on-keystroke in the thought dialog is preserved: `onChanged: (_) => setState(() {})` rebuilds the button, `onPressed: thought.text.trim().isEmpty ? null : _save` — identical semantics to the old `setDialogState` version. The thought `_save` still fire-and-forgets `store.logThought(...)` then pops, exactly as before. |
| 4 | New widget test exercises the real UI path and fails when the fix is reverted | **PASS.** The test pumps the real `HabitsScreen` / `MindTab` (with a real in-memory `AppStore` via `sqflite_ffi` no-isolate factory), taps the real `habits-add` / `habit-menu-1` → `Edit` / `New thought record` buttons, enters text into the real keyed fields, taps the real `Save`, then asserts `takeException()` is null **and** the row persisted (`store.habits.single.name == 'Walk'`, `store.thoughts.single.thought == …`). Reverting the fix (restoring `lib/ui/habits.dart` + `lib/ui/mind.dart` from `b79dc43`) makes **all three** tests fail with the exact crash the commit describes (quotes below). Restoring the fix makes them green again. |
| 5 | analyze + full test suite green | **PASS.** `flutter analyze` clean; full suite `+613: All tests passed!` (baseline before this commit was 610; +3 new tests, no other delta). |

## Non-vacuity proof

Probe applied in the pinned worktree, then reverted (`git checkout -- lib/ui/habits.dart lib/ui/mind.dart`); worktree clean afterwards.

**Revert** — `git show b79dc43:lib/ui/habits.dart > lib/ui/habits.dart` and same for `lib/ui/mind.dart` (restores the caller-created controllers + post-`await showDialog` `dispose()`). Re-ran `flutter test test/dialog_controller_lifecycle_test.dart`:

```
00:01 +0 -3: Some tests failed.

Failing tests:
  test/dialog_controller_lifecycle_test.dart: editing a habit tears the dialog down without an exception
  test/dialog_controller_lifecycle_test.dart: saving a new habit tears the dialog down without an exception
  test/dialog_controller_lifecycle_test.dart: saving a thought record tears the dialog down without an exception
```

Each failure carries the framework exceptions the commit message claims:

```
A TextEditingController was used after being disposed.
...
'_dependents.isEmpty': is not true.
...
The following TestFailure was thrown running a test:
Expected: null
  Actual: 'Multiple exceptions (4) were detected during the running of the current test, and at
least one was unexpected.'
the thought-record controllers were disposed while the route was still animating out
```

(16 `EXCEPTION CAUGHT` blocks across the three tests in the full log.) Restoring the fix re-ran green: `00:01 +3: All tests passed!`.

## Findings

### Major

**m1 — New test file fails the repo's format gate; CI `format` job will fail on this commit.**
- `dart format --output=none --set-exit-if-changed lib test tool` (run after `flutter pub get`, exactly as CI does — `ci.yml` runs `flutter pub get` before the format check) reports `Formatted 102 files (1 changed)` at `0e69cee`; the parent `b79dc43` reports `101 files (0 changed)`. The one changed file is `test/dialog_controller_lifecycle_test.dart`.
- Offending lines (committed file): `:96` (82 cols) `await tester.enterText(find.byKey(const ValueKey('habit-name')), 'Read more');` and `:130` (81 cols) `find.widgetWithText(TextField, 'What happened?'), 'Missed the deadline');`; the formatter also wants the `testWidgets('saving a thought record …'` call at `:104` re-wrapped.
- Fix: run `dart format test/dialog_controller_lifecycle_test.dart` (3-line reflow, no semantic change) and re-run the format gate. No source change.

### Nit

**n1 — Same caller-owned-controller pattern still exists in other dialogs (out of scope, noted for the record).**
- `lib/ui/picker.dart:119` (`_showCreateDialog`), `lib/ui/wealth.dart:128/177-180` (`_showBalanceDialog`, `_showAccountDialog`), and `lib/ui/widgets.dart:260` (`askWorkoutName`) all still create controllers in the caller. `picker`/`wealth` use fire-and-forget `showDialog` (no post-await dispose — a leak per invocation, the audit-F9 class of bug, but not the crash fixed here); `askWorkoutName` disposes in a `finally` after the await — the same timing class as the bug fixed here, though its dialog has no `setState`-driven rebuild so it is less likely to surface. Not touched by this commit; flag for a follow-up, do not block on it.

## Residual risk

- **No device run.** The guard is a widget test; the crash is framework-level (disposed-controller rebuild during route exit animation), which the test reproduces deterministically in the reverted state. Risk is low.
- **`askWorkoutName` and the picker/wealth dialogs** retain the old pattern (n1); they were not reported as crashing and are out of scope for this gate.
