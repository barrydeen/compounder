import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/models.dart';
import '../data/store.dart';
import '../domain/domain.dart';
import '../services/rest_sounds.dart';
import 'widgets.dart';

class SummaryScreen extends StatefulWidget {
  final int workoutId;

  /// Celebrate the session: a one-shot confetti burst, then a walkthrough that
  /// scrolls to each personal record, highlights it and dings it. Only the
  /// finish-workout path sets this — browsing an old session from history
  /// stays quiet and keeps the bottom "Delete workout" button, which is hidden
  /// right after finishing a workout.
  final bool celebrate;

  /// Injectable cue player; tests pass a fake. Defaults to the real
  /// audioplayers-backed implementation.
  final WorkoutSounds? sounds;

  const SummaryScreen(this.workoutId,
      {super.key, this.celebrate = false, this.sounds});

  @override
  State<SummaryScreen> createState() => _SummaryScreenState();
}

class _SummaryScreenState extends State<SummaryScreen>
    with SingleTickerProviderStateMixin {
  /// The detail future is created once so a rebuild (the store notifying, a
  /// theme change, an expansion toggle) never re-queries the database and
  /// never drops the loaded workout back to a loading state.
  late final Future<WorkoutDetail?> _detail;

  /// Personal records for this session, read from the persisted flags so the
  /// summary agrees with what the user was shown during the workout.
  late final Future<List<PrSummary>> _prs;

  /// Workout-exercise ids whose set list is expanded. Held in State so the
  /// expansion survives rebuilds and expanding one exercise does not collapse
  /// another. Collapsed by default: the owner asked to expand "if I want".
  final Set<int> _expanded = <int>{};

  late final WorkoutSounds _sounds;

  /// Drives the one-shot confetti burst. Runs once and stops: a screen that
  /// keeps ticking is both wasteful and a `pumpAndSettle` trap in tests.
  late final AnimationController _confetti;

  /// Global keys for the PR cards, so the walkthrough can scroll to each one.
  final List<GlobalKey> _prKeys = <GlobalKey>[];

  /// The PR card the walkthrough is currently highlighting, or null.
  int? _activePr;

  /// Guards the walkthrough so a rebuild (a store notification, an expansion
  /// toggle) never restarts the celebration.
  bool _prWalkStarted = false;
  bool _prWalkCancelled = false;
  Timer? _prStep;

  @override
  void initState() {
    super.initState();
    _sounds = widget.sounds ?? AudioWorkoutSounds();
    _confetti = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 2600));
    final store = context.read<AppStore>();
    _detail = store.workoutDetail(widget.workoutId);
    _prs = store.prSummary(widget.workoutId);
    // Observe the PR future as soon as it exists: the FutureBuilder only
    // subscribes once the workout detail has loaded, so a query that fails
    // faster than that would otherwise surface as an unhandled async error.
    _prs.then<void>((_) {}, onError: (Object _) {});
    if (widget.celebrate) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) return;
        _confetti.forward(from: 0);
      });
    }
  }

  @override
  void dispose() {
    _prStep?.cancel();
    _confetti.dispose();
    unawaited(_sounds.dispose());
    super.dispose();
  }

  void _toggle(int workoutExerciseId) {
    setState(() {
      if (!_expanded.remove(workoutExerciseId)) {
        _expanded.add(workoutExerciseId);
      }
    });
  }

  /// Starts the PR walkthrough once per session: the confetti is already
  /// running, so now walk the record cards top to bottom, highlighting and
  /// dinging each one.
  void _schedulePrWalk(int count) {
    if (!widget.celebrate || _prWalkStarted || count == 0) return;
    _prWalkStarted = true;
    final store = context.read<AppStore>();
    final reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final withSound = store.restSoundsEnabled;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (withSound) unawaited(_sounds.play(WorkoutCue.personalRecord));
      // Let the fanfare land before the first card lights up.
      _prStep = Timer(const Duration(milliseconds: 700), () {
        if (!mounted) return;
        _advancePrWalk(0, count, reduced: reduced, withSound: withSound);
      });
    });
  }

  void _advancePrWalk(int index, int count,
      {required bool reduced, required bool withSound}) {
    if (!mounted || _prWalkCancelled) return;
    if (index >= count) {
      setState(() => _activePr = null);
      return;
    }
    setState(() => _activePr = index);
    if (withSound) unawaited(_sounds.play(WorkoutCue.prDing));
    if (!reduced && index < _prKeys.length) {
      final target = _prKeys[index].currentContext;
      if (target != null) {
        unawaited(Scrollable.ensureVisible(target,
            duration: const Duration(milliseconds: 420),
            curve: Curves.easeInOut,
            alignment: 0.4));
      }
    }
    _prStep = Timer(const Duration(milliseconds: 1500), () {
      _advancePrWalk(index + 1, count, reduced: reduced, withSound: withSound);
    });
  }

  /// A manual scroll hands control back to the user: the walkthrough stops
  /// rather than fighting their finger.
  bool _onScroll(ScrollNotification notification) {
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      _prStep?.cancel();
      _prWalkCancelled = true;
      if (_activePr != null && mounted) {
        setState(() => _activePr = null);
      }
    }
    return false;
  }

  /// Makes sure every PR card has a stable GlobalKey for the walkthrough. Safe
  /// during build: keys are plain objects, nothing notifies.
  void _ensurePrKeys(int count) {
    while (_prKeys.length < count) {
      _prKeys.add(GlobalKey());
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final scheme = Theme.of(context).colorScheme;

    return FutureBuilder<WorkoutDetail?>(
      future: _detail,
      builder: (context, snap) {
        if (snap.hasError) {
          // A raw DatabaseException string is not user-facing copy; log it and
          // show a fixed subtitle, as progress.dart does (audit F7).
          debugPrint('SummaryScreen(${widget.workoutId}): ${snap.error}');
          return Scaffold(
            appBar: AppBar(title: const Text('Workout summary')),
            body: const Center(
              child: EmptyState(
                title: 'Could not load this workout',
                subtitle: 'Something went wrong reading this workout. '
                    'Pull back and try again.',
                icon: Icons.error_outline,
              ),
            ),
          );
        }
        final detail = snap.data;
        if (detail == null) {
          return const Scaffold(body: Center(child: Text('Workout not found')));
        }
        final completed = detail.exercises
            .expand((e) => e.sets)
            .where((s) => s.completedAt != null)
            .toList();
        final allSets = completed
            .map((s) =>
                (weightKg: s.weightKg, reps: s.reps, isWarmup: s.isWarmup))
            .toList();
        // Zero-rep sets are legal in the store but carry no e1RM (audit B4).
        final working = completed
            .where((s) => !s.isWarmup && s.reps >= 1)
            .map((s) => (s.weightKg, s.reps))
            .toList();
        // Warm-up ("work-up") sets count toward the session totals — the work
        // was performed — but PR detection still ignores them (assessPr).
        final volume = volumeOf(allSets, includeWarmups: true);
        final bestE1rm = working.isEmpty ? 0.0 : formatE1rm(e1rmMaxOf(working));

        return Scaffold(
          appBar: AppBar(title: Text('${detail.workout.name} · summary')),
          body: NotificationListener<ScrollNotification>(
            onNotification: _onScroll,
            child: Stack(children: [
              ListView(
                // Keep the final button (Delete workout) clear of the Android
                // system navigation bar drawn over the body in edge-to-edge
                // mode.
                padding: EdgeInsets.fromLTRB(
                    20, 20, 20, 20 + MediaQuery.paddingOf(context).bottom),
                children: [
                  Text(
                    '${formatDateTime(detail.workout.startedAt)} · ${formatDuration(detail.workout.startedAt, detail.workout.endedAt)}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 12),
                  Row(children: [
                    Expanded(
                        child: StatCard(
                            label: 'Total volume (${store.unit.label})',
                            value:
                                trimZero(fromKg(volume.totalKg, store.unit)))),
                    const SizedBox(width: 8),
                    Expanded(
                        child: StatCard(
                            label: 'Best e1RM (kg)',
                            value: trimZero(bestE1rm))),
                  ]),
                  const SizedBox(height: 8),
                  Row(children: [
                    Expanded(
                        child:
                            StatCard(label: 'Sets', value: '${volume.sets}')),
                    const SizedBox(width: 8),
                    Expanded(
                        child: StatCard(
                            label: 'Total reps', value: '${volume.reps}')),
                  ]),
                  const SizedBox(height: 16),
                  _prSection(store),
                  const SectionHeader('Exercises'),
                  ...detail.exercises.map((view) => _exerciseCard(store, view)),
                  if (!widget.celebrate) ...[
                    const SizedBox(height: 16),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                          foregroundColor: scheme.error),
                      icon: Icon(Icons.delete_outline, color: scheme.error),
                      label: Text('Delete workout',
                          style: TextStyle(color: scheme.error)),
                      onPressed: () async {
                        await store.deleteWorkout(widget.workoutId);
                        if (context.mounted) Navigator.of(context).pop();
                      },
                    ),
                  ],
                ],
              ),
              if (widget.celebrate)
                Positioned.fill(
                  child: IgnorePointer(
                      child: _ConfettiBurst(
                          key: const ValueKey('summary-confetti'),
                          progress: _confetti)),
                ),
            ]),
          ),
        );
      },
    );
  }

  /// The session's personal records, or nothing at all when there are none.
  ///
  /// Each row names the exercise, the previous best and the new best in the
  /// unit the user selected in Settings, plus the delta. A first-ever baseline
  /// reads "First PR" rather than "previous best 0".
  Widget _prSection(AppStore store) {
    return FutureBuilder<List<PrSummary>>(
      future: _prs,
      builder: (context, snap) {
        final scheme = Theme.of(context).colorScheme;
        final t = Theme.of(context).textTheme;
        if (snap.hasError) {
          // A failed PR query must not look like "this session had no PRs":
          // log the raw error and show a quiet inline row instead.
          debugPrint('SummaryScreen(${widget.workoutId}): PR summary failed: '
              '${snap.error}');
          return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SectionHeader('Personal records'),
                const SizedBox(height: 8),
                Text('Could not load personal records for this session.',
                    style:
                        t.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                const SizedBox(height: 16),
              ]);
        }
        final prs = snap.data ?? const <PrSummary>[];
        if (prs.isEmpty) return const SizedBox.shrink();
        _ensurePrKeys(prs.length);
        _schedulePrWalk(prs.length);
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const SectionHeader('Personal records'),
          const SizedBox(height: 8),
          for (var i = 0; i < prs.length; i++) _prCard(i, prs[i], store),
          const SizedBox(height: 16),
        ]);
      },
    );
  }

  /// One personal-record card. The walkthrough makes the active card pop: it
  /// scales up, its trophy grows, a glow spreads behind it and a sparkle marks
  /// it while its ding plays.
  Widget _prCard(int index, PrSummary pr, AppStore store) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final active = _activePr == index;
    const duration = Duration(milliseconds: 260);
    return AnimatedScale(
      key: _ensureKeyAt(index),
      scale: active ? 1.03 : 1,
      duration: duration,
      curve: Curves.easeOutBack,
      child: AnimatedContainer(
        duration: duration,
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          boxShadow: active
              ? [
                  BoxShadow(
                      color: scheme.tertiary.withValues(alpha: 0.55),
                      blurRadius: 24,
                      spreadRadius: 3),
                ]
              : const [],
        ),
        child: Card(
          margin: EdgeInsets.zero,
          color: scheme.tertiaryContainer,
          child: ListTile(
            leading: AnimatedScale(
              scale: active ? 1.3 : 1,
              duration: duration,
              curve: Curves.easeOutBack,
              child:
                  Icon(Icons.emoji_events, color: scheme.onTertiaryContainer),
            ),
            title: Text(pr.exerciseName,
                style:
                    t.titleMedium?.copyWith(color: scheme.onTertiaryContainer)),
            subtitle: Text(_prDetail(pr, store.unit),
                style:
                    t.bodySmall?.copyWith(color: scheme.onTertiaryContainer)),
            trailing: active
                ? Icon(Icons.auto_awesome, color: scheme.onTertiaryContainer)
                : null,
          ),
        ),
      ),
    );
  }

  GlobalKey _ensureKeyAt(int index) => _prKeys[index];

  String _prDetail(PrSummary pr, WeightUnit unit) {
    if (pr.isRepBased) {
      // A bodyweight PR is a rep record: there is no e1RM to show for a 0 kg
      // set, so the row reads in reps.
      final newBest = '${pr.newBestReps} reps';
      if (pr.isBaseline) return 'First PR · $newBest';
      final previous = '${pr.previousBestReps} reps';
      final delta = pr.deltaReps;
      return 'Previous best $previous → new best $newBest '
          '(${delta >= 0 ? '+' : ''}$delta reps)';
    }
    final newBest = '${trimZero(fromKg(pr.newBestKg, unit))} ${unit.label}';
    if (pr.isBaseline) return 'First PR · $newBest';
    final previous =
        '${trimZero(fromKg(pr.previousBestKg, unit))} ${unit.label}';
    final deltaKg = fromKg(pr.deltaKg, unit);
    final delta =
        '${deltaKg >= 0 ? '+' : ''}${trimZero(deltaKg)} ${unit.label}';
    return 'Previous best $previous → new best $newBest ($delta)';
  }

  /// One exercise card: the same aggregate row the summary has always shown,
  /// plus a chevron that reveals the individual sets on demand.
  Widget _exerciseCard(AppStore store, ExerciseView view) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final v = volumeOf(
        view.sets
            .where((s) => s.completedAt != null)
            .map((s) =>
                (weightKg: s.weightKg, reps: s.reps, isWarmup: s.isWarmup))
            .toList(),
        includeWarmups: true);
    final expanded = _expanded.contains(view.entry.id);
    final sets = [...view.sets]
      ..sort((a, b) => a.position.compareTo(b.position));

    return Card(
      color: scheme.surfaceContainerLow,
      child: Column(children: [
        ListTile(
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          leading: const TintedIconCircle(Icons.fitness_center),
          title: Text(view.exercise.name, style: t.titleMedium),
          subtitle: Text(
              '${view.exercise.muscleGroup} · ${v.sets} sets · ${v.reps} reps',
              style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            // Bounded so a large volume cannot squeeze the exercise name on a
            // narrow screen (review nutrition NIT-2).
            Flexible(
              child: Text(
                  '${trimZero(fromKg(v.totalKg, store.unit))} ${store.unit.label}',
                  style: t.labelLarge?.copyWith(color: scheme.primary),
                  textAlign: TextAlign.end,
                  overflow: TextOverflow.ellipsis),
            ),
            const SizedBox(width: 4),
            Semantics(
              container: true,
              button: true,
              toggled: expanded,
              label: '${expanded ? 'Collapse' : 'Expand'} sets for '
                  '${view.exercise.name}',
              onTap: () => _toggle(view.entry.id),
              child: ExcludeSemantics(
                child: IconButton(
                  icon: Icon(expanded ? Icons.expand_less : Icons.expand_more,
                      color: scheme.primary),
                  tooltip: expanded ? 'Collapse sets' : 'Expand sets',
                  onPressed: () => _toggle(view.entry.id),
                ),
              ),
            ),
          ]),
        ),
        if (expanded) ...[
          Divider(height: 1, color: scheme.outlineVariant),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final set in sets) _setRow(store, set),
              ],
            ),
          ),
        ],
      ]),
    );
  }

  /// A read-only set line. Incomplete sets are still listed — a set the user
  /// logged but never ticked off is real data — but they are labelled
  /// "Not completed" and dimmed so they are never read as performed work.
  Widget _setRow(AppStore store, WorkoutSet set) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final done = set.completedAt != null;
    final weight = trimZero(fromKg(set.weightKg, store.unit));
    final detail = '$weight ${store.unit.label} × ${set.reps} reps';
    final status = done ? 'Completed' : 'Not completed';
    // A bodyweight PR is a rep record; a weighted one carries an e1RM snapshot.
    final prLabel = !set.isPr
        ? ''
        : set.prReps != null
            ? ', personal record at ${set.prReps} reps'
            : set.prE1rmKg == null
                ? ', personal record'
                : ', personal record at '
                    '${trimZero(fromKg(set.prE1rmKg!, store.unit))} '
                    '${store.unit.label} estimated 1RM';

    return Semantics(
      container: true,
      label: 'Set ${set.position + 1}, $detail'
          '${set.isWarmup ? ', warm-up' : ''}$prLabel, ${status.toLowerCase()}',
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(children: [
            SizedBox(
              width: 28,
              child: Text('${set.position + 1}',
                  style:
                      t.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
            ),
            Expanded(
              child: Text(detail,
                  style: t.bodyMedium?.copyWith(
                      color:
                          done ? scheme.onSurface : scheme.onSurfaceVariant)),
            ),
            if (set.isPr) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: scheme.tertiaryContainer,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text('PR',
                    style: t.labelSmall
                        ?.copyWith(color: scheme.onTertiaryContainer)),
              ),
            ],
            if (set.isWarmup) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: scheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text('Warm-up',
                    style: t.labelSmall
                        ?.copyWith(color: scheme.onSecondaryContainer)),
              ),
            ],
            const SizedBox(width: 8),
            Text(status,
                style: t.labelSmall
                    ?.copyWith(color: done ? scheme.primary : scheme.outline)),
          ]),
        ),
      ),
    );
  }
}

/// One-shot falling-confetti overlay: a celebration frame over the summary that
/// never intercepts input and paints nothing once the animation finishes.
class _ConfettiBurst extends StatelessWidget {
  final Animation<double> progress;

  const _ConfettiBurst({super.key, required this.progress});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: progress,
      builder: (context, _) {
        if (progress.value >= 1) return const SizedBox.shrink();
        return CustomPaint(
          painter: _ConfettiPainter(progress.value),
          size: Size.infinite,
        );
      },
    );
  }
}

class _ConfettiPainter extends CustomPainter {
  final double t;
  final List<_ConfettiPiece> _pieces;

  _ConfettiPainter(this.t) : _pieces = _buildPieces();

  /// Festive, high-contrast colours that read on both the light and dark
  /// themes without depending on the palette.
  static const _palette = [
    Color(0xFFFFC107),
    Color(0xFFFF4081),
    Color(0xFF40C4FF),
    Color(0xFF69F0AE),
    Color(0xFFB388FF),
    Color(0xFFFF6E40),
  ];

  /// Deterministic: a fixed seed keeps the burst identical run to run, so a
  /// widget test can pump it without surprises.
  static List<_ConfettiPiece> _buildPieces() {
    final rng = math.Random(17);
    return List.generate(70, (_) {
      return _ConfettiPiece(
        x: rng.nextDouble(),
        delay: rng.nextDouble() * 0.25,
        speed: 0.85 + rng.nextDouble() * 0.55,
        sway: (rng.nextDouble() - 0.5) * 0.09,
        size: 4 + rng.nextDouble() * 5,
        spin: (rng.nextDouble() - 0.5) * 10,
        phase: rng.nextDouble() * math.pi * 2,
        color: _palette[rng.nextInt(_palette.length)],
        round: rng.nextBool(),
      );
    });
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    // Fade the whole burst out over its last fifth so it does not just vanish.
    final fade = (1 - ((t - 0.82) / 0.18)).clamp(0.0, 1.0);
    if (fade <= 0) return;
    final paint = Paint();
    for (final piece in _pieces) {
      final local = ((t - piece.delay) / (1 - piece.delay)).clamp(0.0, 1.0);
      if (local <= 0) continue;
      // Gravity: the pieces accelerate as they fall.
      final y =
          -0.15 * size.height + local * local * piece.speed * size.height * 1.4;
      if (y > size.height + 24) continue;
      final x = size.width *
          (piece.x + piece.sway * math.sin(local * 6 + piece.phase));
      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(piece.phase + local * piece.spin * math.pi);
      paint.color = piece.color.withValues(alpha: fade);
      if (piece.round) {
        canvas.drawCircle(Offset.zero, piece.size / 2, paint);
      } else {
        canvas.drawRect(
            Rect.fromCenter(
                center: Offset.zero,
                width: piece.size,
                height: piece.size * 1.6),
            paint);
      }
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_ConfettiPainter oldDelegate) => oldDelegate.t != t;
}

class _ConfettiPiece {
  final double x;
  final double delay;
  final double speed;
  final double sway;
  final double size;
  final double spin;
  final double phase;
  final Color color;
  final bool round;

  const _ConfettiPiece({
    required this.x,
    required this.delay,
    required this.speed,
    required this.sway,
    required this.size,
    required this.spin,
    required this.phase,
    required this.color,
    required this.round,
  });
}
