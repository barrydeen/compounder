import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/models.dart';
import '../data/store.dart';
import '../domain/domain.dart';
import '../services/rest_sounds.dart';
import '../services/rest_timer_background.dart';
import 'picker.dart';
import 'summary.dart';
import 'widgets.dart';

class WorkoutScreen extends StatefulWidget {
  final int workoutId;

  /// Injectable cue player; tests pass a fake. Defaults to the real
  /// audioplayers-backed implementation.
  final WorkoutSounds? sounds;

  /// Injectable background keep-alive for the rest timer; tests pass a fake.
  /// Defaults to the Android foreground-service channel (a no-op elsewhere).
  final RestTimerBackground? restBackground;

  /// Injectable clock for the rest deadline; defaults to [DateTime.now].
  final DateTime Function()? now;

  const WorkoutScreen({
    super.key,
    required this.workoutId,
    this.sounds,
    this.restBackground,
    this.now,
  });

  @override
  State<WorkoutScreen> createState() => _WorkoutScreenState();
}

class _WorkoutScreenState extends State<WorkoutScreen>
    with WidgetsBindingObserver {
  AppStore? _store;
  WorkoutDetail? _detail;
  bool _loading = true;

  final Map<int, TextEditingController> _weightControllers = {};
  final Map<int, TextEditingController> _repsControllers = {};
  final Map<int, FocusNode> _weightFocus = {};
  final Map<int, FocusNode> _repsFocus = {};
  final Map<int, WorkoutSet> _setsById = {};
  final List<ChangeNotifier> _retiredDisposables = [];
  final Set<int> _removingSetIds = {};

  final ValueNotifier<int> _restLeft = ValueNotifier(0);
  Timer? _restTimer;

  /// Wall-clock deadline for the active rest countdown, or null when idle.
  /// Checked on every tick and on app resume so minimizing or OS throttling
  /// can never leave the countdown frozen behind real time.
  DateTime? _restEndAt;

  /// Smallest remaining-second mark whose countdown tick has already fired for
  /// the current rest. Prevents duplicate ticks if a lifecycle resume and a
  /// periodic tick land within the same second.
  int? _lastTickedSecond;

  /// The workout-exercise whose sets are open. Only one card is open at a time
  /// (owner request): the screen exists to log one exercise at a time, and two
  /// open cards just push the next exercise off-screen. The first exercise
  /// opens by default; tapping a header opens it and closes the rest.
  int? _expandedEntryId;
  bool _expandedInitialized = false;

  /// Bumped whenever the rest timer starts, is cancelled or the screen is
  /// disposed. A tick whose generation no longer matches is stale and must not
  /// fire a cue.
  int _restGeneration = 0;

  late final WorkoutSounds _sounds;
  late final RestTimerBackground _restBackground;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _store = context.read<AppStore>();
    _sounds = widget.sounds ?? AudioWorkoutSounds();
    _restBackground =
        widget.restBackground ?? MethodChannelRestTimerBackground();
    _restBackground.setCancelHandler(() {
      if (mounted) _cancelRest(stopBackground: false);
    });
    _loadDetail();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      _syncRestFromClock();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _restBackground.setCancelHandler(null);
    if (_restEndAt != null) unawaited(_restBackground.stop());
    _restTimer?.cancel();
    _restEndAt = null;
    _lastTickedSecond = null;
    _restGeneration++;
    _restLeft.dispose();
    unawaited(_sounds.dispose());
    for (final controller in _weightControllers.values) {
      controller.dispose();
    }
    for (final controller in _repsControllers.values) {
      controller.dispose();
    }
    for (final node in _weightFocus.values) {
      node.dispose();
    }
    for (final node in _repsFocus.values) {
      node.dispose();
    }
    _disposeRetired();
    super.dispose();
  }

  void _disposeRetired() {
    if (_retiredDisposables.isEmpty) return;
    final toDispose = List<ChangeNotifier>.of(_retiredDisposables);
    _retiredDisposables.clear();
    for (final disposable in toDispose) {
      disposable.dispose();
    }
  }

  Future<void> _loadDetail() async {
    final detail = await _store!.workoutDetail(widget.workoutId);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _applyDetail(detail);
    });
  }

  Future<void> _reloadDetail({int? expandEntryId}) async {
    final detail = await _store!.workoutDetail(widget.workoutId);
    if (!mounted) return;
    setState(() => _applyDetail(detail, expandEntryId: expandEntryId));
  }

  /// Installs [detail] and keeps the open card sensible across reloads: a
  /// deleted exercise (or the first load) opens the first remaining card, and
  /// a newly added exercise is opened explicitly by [expandEntryId].
  void _applyDetail(WorkoutDetail? detail, {int? expandEntryId}) {
    _detail = detail;
    final views = detail?.exercises ?? const <ExerciseView>[];
    final ids = views.map((v) => v.entry.id).toSet();
    final keepRequested = expandEntryId != null && ids.contains(expandEntryId);
    if (keepRequested) {
      _expandedEntryId = expandEntryId;
    } else if (!_expandedInitialized ||
        (_expandedEntryId != null && !ids.contains(_expandedEntryId))) {
      _expandedEntryId = views.isEmpty ? null : views.first.entry.id;
    }
    _expandedInitialized = true;
    _syncControllers();
  }

  /// Opens [entryId] and closes whichever card was open. Closing flushes any
  /// half-typed values first: the rows are about to leave the tree and the
  /// user expects what they typed to be saved.
  Future<void> _toggleExercise(ExerciseView view) async {
    if (_expandedEntryId == view.entry.id) {
      await _persistPendingUpdates(_pendingUpdates());
      if (!mounted) return;
      setState(() => _expandedEntryId = null);
      return;
    }
    setState(() => _expandedEntryId = view.entry.id);
  }

  void _syncControllers() {
    final detail = _detail;
    if (detail == null) return;
    final unit = _store!.unit;
    final active = <int>{};
    _setsById.clear();
    for (final view in detail.exercises) {
      for (final set in view.sets) {
        active.add(set.id);
        _setsById[set.id] = set;
        final weightText = trimZero(fromKg(set.weightKg, unit));
        final repsText = set.reps.toString();
        final weightController = _weightControllers.putIfAbsent(
            set.id, () => TextEditingController(text: weightText));
        final repsController = _repsControllers.putIfAbsent(
            set.id, () => TextEditingController(text: repsText));
        final weightNode = _focusFor(set.id, true);
        final repsNode = _focusFor(set.id, false);
        if (!weightNode.hasFocus && weightController.text != weightText) {
          weightController.text = weightText;
        }
        if (!repsNode.hasFocus && repsController.text != repsText) {
          repsController.text = repsText;
        }
      }
    }
    final retired = <ChangeNotifier>[];
    for (final id in _weightControllers.keys.toList()) {
      if (active.contains(id)) continue;
      final weightController = _weightControllers.remove(id);
      final repsController = _repsControllers.remove(id);
      final weightNode = _weightFocus.remove(id);
      final repsNode = _repsFocus.remove(id);
      _setsById.remove(id);
      if (weightController != null) retired.add(weightController);
      if (repsController != null) retired.add(repsController);
      if (weightNode != null) retired.add(weightNode);
      if (repsNode != null) retired.add(repsNode);
    }
    if (retired.isNotEmpty) {
      // Defer disposal until after this frame unmounts the removed TextFields;
      // disposing synchronously inside setState trips ChangeNotifier assertions
      // when EditableTextState.dispose detaches its listeners.
      _retiredDisposables.addAll(retired);
      WidgetsBinding.instance.addPostFrameCallback((_) => _disposeRetired());
    }
  }

  FocusNode _focusFor(int setId, bool weight) {
    final nodes = weight ? _weightFocus : _repsFocus;
    return nodes.putIfAbsent(setId, () {
      final node = FocusNode();
      node.addListener(() {
        if (!node.hasFocus) _saveSetValues(setId);
      });
      return node;
    });
  }

  List<({int id, double weightKg, int reps})> _pendingUpdates() {
    final unit = _store!.unit;
    final updates = <({int id, double weightKg, int reps})>[];
    for (final entry in _setsById.entries) {
      final weightController = _weightControllers[entry.key];
      final repsController = _repsControllers[entry.key];
      if (weightController == null || repsController == null) {
        continue;
      }
      final parsedWeight = parseWeightKg(weightController.text, unit);
      final parsedReps = int.tryParse(repsController.text.trim());
      if (parsedWeight == null || parsedReps == null) {
        continue;
      }
      final weightKg = parsedWeight < 0 ? 0.0 : parsedWeight;
      final reps = parsedReps < 0 ? 0 : parsedReps;
      final set = entry.value;
      if ((weightKg - set.weightKg).abs() < 0.0001 && reps == set.reps) {
        continue;
      }
      updates.add((id: entry.key, weightKg: weightKg, reps: reps));
    }
    return updates;
  }

  Future<void> _persistPendingUpdates(
      List<({int id, double weightKg, int reps})> updates) async {
    for (final update in updates) {
      await _store!
          .updateSet(update.id, weightKg: update.weightKg, reps: update.reps);
    }
    if (updates.isNotEmpty) await _reloadDetail();
  }

  Future<void> _saveSetValues(int setId, {bool reload = true}) async {
    final set = _setsById[setId];
    final weightController = _weightControllers[setId];
    final repsController = _repsControllers[setId];
    if (set == null || weightController == null || repsController == null) {
      return;
    }
    final unit = _store!.unit;
    final parsedWeight = parseWeightKg(weightController.text, unit);
    final parsedReps = int.tryParse(repsController.text.trim());
    if (parsedWeight == null) {
      weightController.text = trimZero(fromKg(set.weightKg, unit));
    }
    if (parsedReps == null) {
      repsController.text = set.reps.toString();
    }
    if (parsedWeight == null || parsedReps == null) return;
    final weightKg = parsedWeight < 0 ? 0.0 : parsedWeight;
    final reps = parsedReps < 0 ? 0 : parsedReps;
    if ((weightKg - set.weightKg).abs() < 0.0001 && reps == set.reps) return;
    await _store!.updateSet(setId, weightKg: weightKg, reps: reps);
    if (reload) await _reloadDetail();
  }

  DateTime _now() => widget.now?.call() ?? DateTime.now();

  int _wallRemainingSeconds() {
    final endAt = _restEndAt;
    if (endAt == null) return 0;
    final remainingMs = endAt.difference(_now()).inMilliseconds;
    if (remainingMs <= 0) return 0;
    return (remainingMs + 999) ~/ 1000;
  }

  void _applyRestRemaining(int next) {
    final clamped = next < 0 ? 0 : next;
    _restLeft.value = clamped;
    if (clamped <= 0) {
      _restTimer?.cancel();
      _restTimer = null;
      _restEndAt = null;
      _lastTickedSecond = null;
      _restGeneration++;
      _playCue(WorkoutCue.go);
      // Keep the foreground service / wake lock briefly while the ~230 ms "go"
      // WAV finishes playing if the screen is off.
      unawaited(_restBackground.stop(graceMs: 800));
      return;
    }
    if (clamped <= 5 &&
        (_lastTickedSecond == null || clamped < _lastTickedSecond!)) {
      _lastTickedSecond = clamped;
      _playCue(WorkoutCue.countdownTick);
    }
  }

  void _syncRestFromClock() {
    if (_restEndAt == null) return;
    final wallLeft = _wallRemainingSeconds();
    if (wallLeft < _restLeft.value) {
      _applyRestRemaining(wallLeft);
    }
  }

  void _startRest() {
    final seconds = _store!.restSeconds;
    _restTimer?.cancel();
    _restGeneration++;
    _restLeft.value = seconds;
    _lastTickedSecond = null;
    if (seconds <= 0) {
      _restEndAt = null;
      unawaited(_restBackground.stop());
      return;
    }
    final endAt = _now().add(Duration(seconds: seconds));
    _restEndAt = endAt;
    if (_sounds case final AudioWorkoutSounds audio) {
      unawaited(audio.preload(WorkoutCue.countdownTick));
      unawaited(audio.preload(WorkoutCue.go));
    }
    unawaited(_restBackground.start(endAt: endAt));
    final generation = _restGeneration;
    // One tick for every second of the final countdown (5, 4, 3, 2, 1), then
    // the distinct go tone at zero. A rest configured at or below five seconds
    // (the Settings minimum is 5s) starts inside the countdown window, so its
    // first tick fires now: waiting for the first timer tick would place it at
    // 4s remaining, one second late.
    if (seconds <= 5) {
      _lastTickedSecond = seconds;
      _playCue(WorkoutCue.countdownTick);
    }
    _restTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted || generation != _restGeneration) {
        timer.cancel();
        return;
      }
      final decremented = _restLeft.value - 1;
      final wallLeft = _wallRemainingSeconds();
      final next = wallLeft < decremented ? wallLeft : decremented;
      _applyRestRemaining(next);
    });
  }

  /// Cancels the rest timer without a cue (the user tapped the rest chip or
  /// the background notification's Cancel action).
  void _cancelRest({bool stopBackground = true}) {
    _restTimer?.cancel();
    _restTimer = null;
    _restEndAt = null;
    _lastTickedSecond = null;
    _restGeneration++;
    _restLeft.value = 0;
    if (stopBackground) unawaited(_restBackground.stop());
  }

  /// Plays a workout cue unless the user muted workout sounds. The mute
  /// switch covers the rest cues and the PR celebration alike.
  void _playCue(WorkoutCue cue) {
    if (!mounted) return;
    if (!(_store?.restSoundsEnabled ?? false)) return;
    unawaited(_sounds.play(cue));
  }

  Future<void> _toggleWarmup(WorkoutSet set, bool warmup) async {
    await _saveSetValues(set.id, reload: false);
    await _store!.updateSet(set.id, warmup: warmup);
    await _reloadDetail();
  }

  Future<void> _toggleComplete(WorkoutSet set) async {
    if (set.completedAt != null) {
      await _store!.updateSet(set.id, completedAt: 0);
      await _reloadDetail();
      return;
    }
    await _saveSetValues(set.id, reload: false);
    await _store!
        .updateSet(set.id, completedAt: DateTime.now().millisecondsSinceEpoch);
    await _reloadDetail();
    // The store recomputes the session's PR flags on every set change, so the
    // reloaded row is the authoritative verdict. Celebrate only when this set
    // is now a PR; the mute switch is honoured inside _playCue.
    if (_setsById[set.id]?.isPr ?? false) {
      _playCue(WorkoutCue.personalRecord);
    }
    _startRest();
  }

  Future<void> _addSet(ExerciseView view) async {
    final last = view.sets.isEmpty ? null : view.sets.last;
    if (last != null) await _saveSetValues(last.id, reload: false);
    final unit = _store!.unit;
    final weightController = last == null ? null : _weightControllers[last.id];
    final repsController = last == null ? null : _repsControllers[last.id];
    final weightKg = (weightController == null
            ? null
            : parseWeightKg(weightController.text, unit)) ??
        last?.weightKg ??
        0;
    final reps = (repsController == null
            ? null
            : int.tryParse(repsController.text.trim())) ??
        last?.reps ??
        0;
    await _store!.addSet(
        view.entry.id, weightKg < 0 ? 0 : weightKg, reps < 0 ? 0 : reps,
        completed: false);
    await _reloadDetail();
  }

  Future<void> _removeSet(WorkoutSet set) async {
    if (!_removingSetIds.add(set.id)) return;
    try {
      // Flush any half-typed edits in sibling rows so removing one set never
      // discards what the user typed into another.
      final updates = _pendingUpdates().where((u) => u.id != set.id).toList();
      for (final update in updates) {
        await _store!
            .updateSet(update.id, weightKg: update.weightKg, reps: update.reps);
      }
      await _store!.deleteSetRow(set.id);
      await _reloadDetail();
    } finally {
      _removingSetIds.remove(set.id);
    }
  }

  Widget _restChip(ColorScheme scheme) {
    return ValueListenableBuilder<int>(
      valueListenable: _restLeft,
      builder: (context, restLeft, _) {
        if (restLeft <= 0) return const SizedBox.shrink();
        return Center(
          child: Padding(
            padding: const EdgeInsets.only(right: 12),
            child: ActionChip(
              avatar: Icon(Icons.timer, size: 16, color: scheme.primary),
              label: Text(
                  '${restLeft ~/ 60}:${(restLeft % 60).toString().padLeft(2, '0')}'),
              onPressed: _cancelRest,
            ),
          ),
        );
      },
    );
  }

  Widget _setHeader(ColorScheme scheme, TextTheme t, String unitLabel) {
    final style =
        t.labelSmall?.copyWith(color: scheme.onSurfaceVariant, fontSize: 10);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(children: [
        SizedBox(width: 20, child: Text('#', style: style)),
        Expanded(
          flex: 3,
          child: Text('Weight ($unitLabel)',
              style: style, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        const SizedBox(width: 4),
        Expanded(
          flex: 2,
          child: Text('Reps',
              style: style, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        const SizedBox(width: 4),
        SizedBox(
            width: 48,
            child: Text('Warm-up',
                style: style, textAlign: TextAlign.center, maxLines: 2)),
        SizedBox(
            width: 48,
            child: Text('Done', style: style, textAlign: TextAlign.center)),
        const SizedBox(width: 48),
      ]),
    );
  }

  Widget _setRow(BuildContext context, ColorScheme scheme, TextTheme t,
      ExerciseView view, int index, WorkoutSet set) {
    final weightController = _weightControllers[set.id];
    final repsController = _repsControllers[set.id];
    if (weightController == null || repsController == null) {
      return const SizedBox.shrink();
    }
    final weightNode = _focusFor(set.id, true);
    final repsNode = _focusFor(set.id, false);
    final done = set.completedAt != null;
    return Padding(
      key: ValueKey('set-row-${set.id}'),
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          SizedBox(
            width: 20,
            child: Text('${index + 1}',
                style: t.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
          ),
          Expanded(
            flex: 3,
            child: TextField(
              controller: weightController,
              focusNode: weightNode,
              onSubmitted: (_) => _saveSetValues(set.id),
              onTapOutside: (_) => FocusScope.of(context).unfocus(),
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              textAlign: TextAlign.center,
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 4, vertical: 8),
              ),
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            flex: 2,
            child: TextField(
              controller: repsController,
              focusNode: repsNode,
              onSubmitted: (_) => _saveSetValues(set.id),
              onTapOutside: (_) => FocusScope.of(context).unfocus(),
              keyboardType: TextInputType.number,
              textAlign: TextAlign.center,
              decoration: const InputDecoration(
                isDense: true,
                hintText: '0',
                border: OutlineInputBorder(),
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 4, vertical: 8),
              ),
            ),
          ),
          const SizedBox(width: 4),
          SizedBox(
            width: 48,
            child: Tooltip(
              message: 'Warm-up set',
              child: Checkbox(
                value: set.isWarmup,
                onChanged: (value) => _toggleWarmup(set, value ?? false),
              ),
            ),
          ),
          SizedBox(
            width: 48,
            child: Tooltip(
              message: done ? 'Mark set incomplete' : 'Mark set complete',
              child: Checkbox(
                value: done,
                onChanged: (_) => _toggleComplete(set),
              ),
            ),
          ),
          SizedBox(
            width: 48,
            child: IconButton(
              icon: Icon(Icons.close, size: 18, color: scheme.outline),
              tooltip: 'Remove set ${index + 1}',
              onPressed: () => _removeSet(set),
            ),
          ),
        ]),
        // The badge sits on its own line: the set row already fills a 320dp
        // screen, so an inline chip would overflow at accessibility text
        // scales.
        if (set.isPr)
          Padding(
            padding: const EdgeInsets.only(left: 20, top: 4),
            child: _prBadge(scheme, t, set),
          ),
      ]),
    );
  }

  /// The personal-record badge shown under a qualifying set. A weighted PR
  /// renders its e1RM snapshot in the unit the user selected in Settings; a
  /// bodyweight (0 kg) PR renders its rep snapshot instead.
  Widget _prBadge(ColorScheme scheme, TextTheme t, WorkoutSet set) {
    final unit = _store!.unit;
    final reps = set.prReps;
    final snapshot = set.prE1rmKg;
    final value = snapshot == null ? null : trimZero(fromKg(snapshot, unit));
    final label = reps != null
        ? 'Personal record: $reps reps'
        : value == null
            ? 'Personal record'
            : 'Personal record: $value ${unit.label} estimated 1RM';
    final text = reps != null
        ? 'PR · $reps reps'
        : value == null
            ? 'PR'
            : 'PR · $value ${unit.label} e1RM';
    return Semantics(
      container: true,
      label: label,
      child: ExcludeSemantics(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: scheme.tertiaryContainer,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.emoji_events,
                size: 14, color: scheme.onTertiaryContainer),
            const SizedBox(width: 4),
            Text(
              text,
              style: t.labelSmall?.copyWith(
                  color: scheme.onTertiaryContainer,
                  fontWeight: FontWeight.w700),
            ),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final detail = _detail;

    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Workout')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (detail == null) {
      return const Scaffold(body: Center(child: Text('Workout not found')));
    }

    final volume = volumeOf(
        detail.exercises
            .expand((e) => e.sets)
            .where((s) => s.completedAt != null)
            .map((s) =>
                (weightKg: s.weightKg, reps: s.reps, isWarmup: s.isWarmup)),
        // Warm-up ("work-up") sets count toward the session total; only PR
        // detection ignores them.
        includeWarmups: true);

    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) unawaited(_persistPendingUpdates(_pendingUpdates()));
      },
      child: Scaffold(
        appBar: AppBar(
          toolbarHeight: 72,
          title: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(detail.workout.name,
                  style: t.titleMedium,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
              _ElapsedTimer(
                  startedAt: detail.workout.startedAt,
                  endedAt: detail.workout.endedAt),
            ],
          ),
          actions: [
            _restChip(scheme),
            if (detail.workout.active)
              TextButton(
                onPressed: () async {
                  await _persistPendingUpdates(_pendingUpdates());
                  await store.finishWorkout(widget.workoutId);
                  if (!context.mounted) return;
                  Navigator.of(context).pushReplacement(MaterialPageRoute(
                      builder: (_) =>
                          SummaryScreen(widget.workoutId, celebrate: true)));
                },
                child: Text('Finish',
                    style: TextStyle(
                        color: scheme.primary, fontWeight: FontWeight.w700)),
              ),
          ],
        ),
        body: ListView(
          // Edge-to-edge Android draws the body behind the system navigation
          // bar (back / home / recents). Without the inset as extra bottom
          // padding the last child — the Add exercise button — ends up
          // underneath it.
          padding: EdgeInsets.fromLTRB(
              20, 20, 20, 20 + MediaQuery.paddingOf(context).bottom),
          children: [
            Row(children: [
              Expanded(
                  child: StatCard(
                      label: 'Volume (${store.unit.label})',
                      value: trimZero(fromKg(volume.totalKg, store.unit)))),
              const SizedBox(width: 8),
              Expanded(
                  child: StatCard(
                      label: 'Sets · reps',
                      value: '${volume.sets} · ${volume.reps}')),
            ]),
            const SizedBox(height: 16),
            if (detail.exercises.isEmpty)
              const EmptyState(
                title: 'Empty workout',
                subtitle: 'Add your first exercise to start logging sets.',
                icon: Icons.add_chart,
              ),
            ...detail.exercises.map((view) => Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _exerciseCard(store, scheme, t, view),
                )),
            const SizedBox(height: 4),
            // The add button lives under the last exercise card (owner
            // request): it is the natural "what next" position once the sets
            // in front of the user are filled in.
            OutlinedButton.icon(
              onPressed: () async {
                final exerciseId = await Navigator.of(context).push<int>(
                    MaterialPageRoute(
                        builder: (_) => const ExercisePickerScreen()));
                if (exerciseId == null) return;
                final int entryId;
                try {
                  entryId = await _store!.addExerciseToWorkout(
                      widget.workoutId, exerciseId,
                      seedDefaultSet: true);
                } on StoreException catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context)
                        .showSnackBar(SnackBar(content: Text(e.message)));
                  }
                  return;
                }
                await _reloadDetail(expandEntryId: entryId);
              },
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add exercise'),
            ),
          ],
        ),
      ),
    );
  }

  /// One exercise card: a tappable header that opens or closes the set table.
  /// Only one card is open at a time, so opening this one is all it takes.
  Widget _exerciseCard(
      AppStore store, ColorScheme scheme, TextTheme t, ExerciseView view) {
    final expanded = _expandedEntryId == view.entry.id;
    final summary = volumeOf(
        view.sets
            .where((s) => s.completedAt != null)
            .map((s) =>
                (weightKg: s.weightKg, reps: s.reps, isWarmup: s.isWarmup))
            .toList(),
        includeWarmups: true);
    return Card(
      color: scheme.surfaceContainerLow,
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 4, 4),
          child: Row(children: [
            Expanded(
              child: Semantics(
                container: true,
                button: true,
                toggled: expanded,
                label: '${expanded ? 'Collapse' : 'Expand'} sets for '
                    '${view.exercise.name}',
                onTap: () => _toggleExercise(view),
                child: ExcludeSemantics(
                  child: InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => _toggleExercise(view),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 8),
                      child: Row(children: [
                        Expanded(
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(view.exercise.name, style: t.titleMedium),
                                Text(
                                    '${view.exercise.muscleGroup} · '
                                    '${summary.sets} sets · '
                                    '${summary.reps} reps',
                                    style: t.bodySmall?.copyWith(
                                        color: scheme.onSurfaceVariant)),
                              ]),
                        ),
                        Icon(expanded ? Icons.expand_less : Icons.expand_more,
                            color: scheme.primary),
                      ]),
                    ),
                  ),
                ),
              ),
            ),
            IconButton(
              icon: Icon(Icons.delete_outline, color: scheme.outline),
              tooltip: 'Remove exercise',
              onPressed: () async {
                await _persistPendingUpdates(_pendingUpdates());
                await _store!.removeExercise(view.entry.id);
                await _reloadDetail();
              },
            ),
          ]),
        ),
        if (expanded)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 4, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (view.sets.isNotEmpty)
                  _setHeader(scheme, t, store.unit.label),
                ...view.sets.asMap().entries.map((entry) =>
                    _setRow(context, scheme, t, view, entry.key, entry.value)),
                TextButton.icon(
                  onPressed: () => _addSet(view),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add set'),
                ),
              ],
            ),
          ),
      ]),
    );
  }
}

class _ElapsedTimer extends StatefulWidget {
  final int startedAt;
  final int? endedAt;

  const _ElapsedTimer({required this.startedAt, this.endedAt});

  @override
  State<_ElapsedTimer> createState() => _ElapsedTimerState();
}

class _ElapsedTimerState extends State<_ElapsedTimer> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _syncTimer();
  }

  @override
  void didUpdateWidget(covariant _ElapsedTimer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.startedAt != widget.startedAt ||
        oldWidget.endedAt != widget.endedAt) {
      _syncTimer();
    }
  }

  void _syncTimer() {
    _timer?.cancel();
    if (widget.endedAt == null) {
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final label = widget.endedAt == null ? 'Elapsed' : 'Duration';
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(Icons.timer_outlined, size: 14, color: scheme.primary),
      const SizedBox(width: 4),
      // The AppBar title is width-constrained; at 320dp with the Android
      // maximum font scale the timer text must shrink rather than overflow.
      Flexible(
        child: Text(
          '$label ${formatDuration(widget.startedAt, widget.endedAt)}',
          style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    ]);
  }
}
