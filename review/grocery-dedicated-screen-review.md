# Gate review — dedicated grocery screen + AI auto-suggest removal (0.6.0+12)

- **Task**: Code review gate: grocery dedicated screen + auto-suggest removal (ref task f764a260)
- **HEAD reviewed**: `6cb2464` ("chore(release): bump version to 0.6.0+12 for dedicated grocery screens")
- **Range reviewed**: `c079121..6cb2464` — `a8bfdd2` (feat), `282177a` (widget/store tests), `3b64f9e` (integration smoke), `6cb2464` (version bump)
- **Worktree**: `/home/barry/.cache/gate-compounder` (detached at `6cb2464`; gates and revert proofs run there, not in the shared checkout)
- **Date**: 2026-11-12
- **Verdict**: **APPROVE** — no blockers, no majors. Two nits, neither blocking.

## What changed

- `lib/ui/grocery.dart` (331 lines) rewritten: two StatefulWidgets — `GroceryListsScreen` (index: create + delete, item/checked counts, quick-add from purchase history) and `GroceryListScreen` (detail: add, tick, clear ticked, buy-again). Every trace of the LLM suggest path is gone.
- `lib/domain/grocery.dart` −56 lines: suggest prompts, `parseGrocerySuggestion`, `prefGrocerySuggest`. Kept: length limits, `groceryTextKey`, `groceryItemError`/`groceryListError`, `grocerySuggestionLimit`.
- `lib/data/store.dart` −9 lines: `grocerySuggestEnabled`/`setGrocerySuggestEnabled` pref plumbing. All CRUD, validation and purchase-history ranking intact.
- `lib/ui/macros.dart`: Diet top-bar gains the cart `IconButton` → `GroceryListsScreen`; the embedded `GrocerySection` and its dialog are gone.
- `lib/main.dart` +5: `bootstrapForTest()` alias (see Nit 1).
- Tests: `test/grocery_widget_test.dart` rewritten around the new screens incl. a source-level negative proof; `test/grocery_store_test.dart` drops the removed parse-fn group; new `integration_test/grocery_smoke_test.dart`.
- `pubspec.yaml`: version 0.6.0+12; `integration_test` added under `dev_dependencies` (test-only, not shipped).

## What I verified (commands + results, all in the pinned worktree unless noted)

1. **Orphan hunt** — grepped `lib/`, `test/`, `integration_test/` for all removed identifiers (`prefGrocerySuggest`, `grocerySuggestEnabled`, `setGrocerySuggestEnabled`, `parseGrocerySuggestion`, `grocerySuggestSystemPrompt`, `GrocerySection`, `_maybeSuggest`, `_suggestion*`, `grocery-suggest-toggle`, `ChatClient`, `llm/` in grocery UI). Only matches are the negative assertions inside `test/grocery_widget_test.dart:282-294` — the intended shape. `flutter analyze` clean, so nothing else references them. `domain/grocery.dart` is imported only by store, coach tools, grocery UI and the two grocery tests.
2. **Navigation** — single entry point: cart button at `lib/ui/macros.dart:186-190`; detail screen reached only from the index tap; index appBar create-dialog; back navigation via default pop; delete confirms → `store.deleteGroceryList` → `Navigator.of(context).pop()` (`grocery.dart:130-152`) with the index rebuilding off `context.watch`. No ambient selected-list state: the detail screen resolves `store.groceryLists.firstWhere((l) => l.id == widget.listId, orElse: () => list)` every build, so a stale id after delete degrades to the local `list`, never a lookup crash.
3. **Controller hygiene** — both StatefulWidgets dispose: `_itemController` (`grocery.dart:106-108`) and the dialog `_controller` (`grocery.dart:291-293`).
4. **Store boundary** — UI catches `StoreException` at `grocery.dart:26` (create) and `:123` (add item) and surfaces `e.message`; validation lives in the store (`groceryListError` at `store.dart:1676`, `groceryItemError` at `:1703`). Zero sqflite access in `lib/ui/` (grep clean). `build()` uses `context.watch` + in-memory filters (`groceryItemsFor`, `grocerySuggestionsFor`, `store.purchases` are list getters) — no DB queries inside build.
5. **History + coach** — `GroceryHistoryTool` (`get_grocery_history`, `lib/coach/tools.dart:1761+`) untouched and covered by `test/grocery_coach_test.dart`; purchase-history ranking covered by `test/grocery_store_test.dart` (`grocerySuggestionsFor` at `:247`) and the buy-again widget/integration flows.
6. **Gates** — `make format` → `Formatted 108 files (0 changed)`; `dart format --output=none --set-exit-if-changed integration_test` → 0 changed; `make analyze` → `No issues found!`; `make test` → `00:19 +648: All tests passed!` (shared checkout, clean tree).
7. **Emulator** — at the reviewed commit in the pinned worktree: `TMPDIR=/home/barry/.cache/flutter-tmp JAVA_HOME=$(ls -d /home/barry/.local/share/mise/installs/java/*/ | head -1) flutter test --no-pub -d emulator-5554 integration_test/grocery_smoke_test.dart` → `00:32 +1: All tests passed!` (assembleDebug 28.2s). The smoke test asserts the real journey: Diet → cart → create list → add/tick → buy-again → delete, plus `find.byType(GroceryChatClient)`-absence of LLM plumbing via a no-ChatClient construction of the screens.

## Non-vacuous guard proofs (revert → quoted failure)

- **Guard A — navigation test is real.** In the pinned worktree, removed the cart `IconButton` from `lib/ui/macros.dart` (the only entry point). `flutter test test/grocery_widget_test.dart`:
  `This was caught by the test expectation on the following line: file:///home/barry/.cache/gate-compounder/test/grocery_widget_test.dart line 71` — `expect(find.byTooltip('Grocery lists'), findsOneWidget, reason: 'cart action sits beside the meal-gallery action')`. Result `+7 -1`: only the navigation test failed; the other 7 still passed, so the failure is attributable to the removed entry point, not collateral. Guard proven non-vacuous.
- **Guard B — removal-completeness test is real.** Restored `lib/data/store.dart` + `lib/domain/grocery.dart` from `c079121` (pre-removal). `flutter test test/grocery_widget_test.dart`:
  `Expected: false / Actual: <true>` — `expect(storeSource.contains('grocerySuggestEnabled'), isFalse)` at `test/grocery_widget_test.dart:289`. The guard fails exactly when the pref plumbing returns. Guard proven non-vacuous.

Both reverts restored with `git checkout`; worktree clean at `6cb2464` afterwards.

## Findings

### Nit 1 — `bootstrapForTest()` is a test-only alias living in shipped `lib/main.dart`
`lib/main.dart:12-19`. The doc comment says it exists so `integration_test` can boot the app, but `import 'package:compounder/main.dart' as app;` + `app.main()` works without the alias (the integration test already imports `as app`). Dead weight in production and a foot-gun if `main()` ever gains startup-idempotency requirements. Opinion-level; not blocking. Owner may keep it if the alias is deliberate.

### Nit 2 — integration smoke test wipes grocery data on whatever device it runs on
`integration_test/grocery_smoke_test.dart:27-31` deletes every existing grocery list and clears `purchases` before the flow. Correct for the emulator/test device, but if someone ever runs the integration test against an install with real data, that data is gone. A comment noting the destructive setUp (or a device-name guard) would prevent an accident. Not blocking; standard practice for integration tests.

## Verdict record

Gates at `6cb2464`: format clean, analyze clean, 648/648 tests green, emulator smoke green, both new guards proven non-vacuous by revert with quoted failures. **APPROVE.**
