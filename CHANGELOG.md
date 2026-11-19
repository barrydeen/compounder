# Changelog

All notable changes to Compounder are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[semantic versioning](https://semver.org/spec/v2.0.0.html). Release tags are
`v<major>.<minor>.<patch>`; the Android/iOS build number lives in
`pubspec.yaml` as the `+<n>` suffix.

This file was seeded from the repository history at the point the project moved
to `github.com/arcane-growth`. Earlier entries are summarised from commit
history, not from contemporaneous release notes.

## [Unreleased] — 0.4.0+10

Release candidate. Not yet tagged.

### Added

- **App icon and in-app mark** — a compounding-spiral logo replaces the default
  Flutter launcher icon on Android and iOS (legacy and adaptive icons, including
  an Android 13 themed-icon silhouette), and the same mark appears in the home
  app bar and drawer header (`assets/logo.png`).
- **Day planner and planning pillar** — chronological day planning with schema
  v13 `plan_blocks`, plus coach tools to read, add, move, check off and delete
  plan blocks.
- **Personal records** — detection, celebration, workout summary and history
  views for new bests.
- **Rest-timer audio cues** — 5-second warning tick, go tone at zero, and a mute
  setting.
- **Activity heatmap and gamified daily home screen** — streak and consistency
  view over logged activity.
- **Habit tracker** — schema v10 CRUD, coach tools, backup format 4.
- **Nutrition browsing by date** with a weekly macro/calorie tracker.
- **Manual meal logging** and a macro-to-calorie calculator.
- **Expand/collapse per-set detail** in past workout summaries.
- **Workout summary celebration** — finishing a workout lands on a confetti
  burst, then a walkthrough that scrolls to each personal record, highlights it
  and dings it (a new `pr_ding.wav` cue after one fanfare). Opening an older
  session from History stays quiet, the existing Workout sounds mute switch
  silences the audio, and the animations are skipped when the platform asks for
  reduced motion.
- **Live workout cards** — the live workout screen opens one exercise card at a
  time; tapping a header expands it and collapses the rest, adding an exercise
  opens the new card, and the "Add exercise" button now sits below the last
  card.
- **Compounder AI subscription** — Play/StoreKit purchase, gateway verification,
  source routing, trialing and past-due grace states.
- **Fitness tab and navigation split** — bottom bar Home/Fitness/Macros/Wealth/
  Coach; Mind moved to the drawer.

### Changed

- Rest-timer cues tick once on each of the final five seconds (5, 4, 3, 2, 1)
  instead of a single tick at five; the distinct "go" tone still plays at zero.
- Warm-up ("work-up") sets now count toward the session's volume, sets and reps
  totals in the live workout header and the summary (the summary's "Working
  sets" stat is now "Sets"); personal-record detection still ignores them.
- The local `make test` target runs a bounded number of test workers and keeps
  `TMPDIR` off tmpfs: a bare `flutter test` sizes its worker pool to the core
  count, and an interrupted run can leave orphaned test processes that make the
  next run appear to hang.
- Daily coach check-in: notifications are expandable in the shade (BigText), and
  the message names what is still open today — overdue training, protein gap,
  mood check-in, unfinished habits, remaining plan blocks and unchecked
  shopping — and ends with one concrete action instead of summarizing totals.
- Settings only shows the "Your own endpoint" fields (base URL, token, model,
  save button) while that source is selected, so the form is not presented for
  an endpoint that is not in use.
- Sleep durations are shown and quoted as hours and minutes ("2H 30M") in the
  health screens, the home summary and the coach's health tools instead of raw
  minute counts, and the coach is told to repeat them verbatim.
- CI is now a single fast job (format check, analyze, tests) on pushes to
  `main` and on pull requests: the per-PR release build (~9 minutes), the
  gitleaks scan and the second UTC test pass were dropped, and `main` has no
  branch protection while the app is in development — direct pushes are
  allowed and CI reports status without blocking merges.
- Release builds are minified and resource-shrunk with R8 and obfuscated Dart
  symbols; symbol files are archived with each artifact.
- Release signing fails loudly when `android/key.properties` is missing instead
  of silently falling back to the debug key.
- Version bumped to `0.4.0+10`; `appVersionLabel` is asserted against
  `pubspec.yaml` by a test so the two cannot drift.

### Fixed

- Coach planner: non-finite plan times guarded, days isolated, stale-day load
  guard, midnight marker rollover.
- Workout: PR prior-best scoped to earlier sessions; one session baseline shared
  across duplicate entries; elapsed timer ellipsised at narrow widths.
- Coach approval card: the Approve button was clipped off-screen.
- Meal edit no longer loses data on a no-op edit.
- Backup import: exercise ids remapped so workout history keeps its exercises;
  unknown-column imports no longer abort.
- Net-worth history is deterministic and database-derived.
- Coach turn history is bounded and trimmed on turn boundaries so a request never
  starts with `role: tool`.
- Calendar-day arithmetic replaces `Duration` day stepping (DST correctness).
- Health Connect sync: 1-day chunking, `largeHeap`, resumable per-chunk sync;
  sleep history loss fixed with composite sleep UUIDs and schema 5/6/7 recovery.

### Security

- CI now runs a gitleaks scan over every commit on every ref.
- Dependabot monitors `pub` and `github-actions`.
- Workflows run with least-privilege `permissions` and third-party actions pinned
  to commit SHAs.
- Repository hygiene: signing material, `.env*`, local SDK paths and build
  reports are gitignored; a tracked Gradle build report was removed.

## [0.3.1] — 2026-11-05

### Added

- Meal notes and a meal gallery.
- Gallery meal picker restored.

### Changed

- Health tab renamed to Fitness; number formatting unified.

### Fixed

- Sleep total calculation.
- Integer breathing countdown restored.

## [0.3.0] — 2026-11-05

### Added

- Google Health Connect import (read-only) with coach health tools across sleep,
  heart rate, HRV, steps, distance, calories, workouts, body measurements and
  vitals.
- MIT LICENSE file added (the README already claimed MIT).

### Fixed

- Health Connect sync OOM: 1-day chunking, `largeHeap`, resumable per-chunk sync.
- Sleep history loss: composite sleep UUIDs and schema 5/6/7 recovery.

## [0.2.2] — 2026-11-05

### Added

- Net-worth trend and quick balance updates.
- Workout logging overhaul.

## [0.2.1] — 2026-09-12

### Fixed

- Startup hang when the configured AI endpoint is unreachable.

## [0.2.0] — 2026-09-12

### Added

- File uploads, financial upside tools, reminders, markdown rendering and guided
  breathing.

## [0.1.0] — 2026-09-12

### Added

- Initial release: Flutter port of OpenFit expanded into health, wealth and mind
  domains, with a bring-your-own-AI coach.
