/// Every screen must be reachable from somewhere else in the app.
///
/// TutorVocabScreen — the 영어식 사고 작문 튜터 — went dark for months: the
/// chat-centric rework removed the 학습 탭 it launched from and never gave it a
/// new home. Nothing failed. It compiled, it shipped, `/tutor/vocab` kept
/// serving the expressions already saved in it, and no test noticed that no
/// code path could open it.
///
/// This is the cheapest check that would have caught it: a screen class nobody
/// names outside its own file cannot be opened by anybody.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Screens that legitimately have no reference from other Dart files.
///
/// Add an entry only with a reason. "It's not wired up yet" is a reason to
/// finish wiring it up, not to add it here.
const _allowedUnreferenced = <String, String>{};

/// Matches a public top-level screen declaration: `class FooScreen extends …`.
///
/// Leading capital required, so library-private classes are skipped: `_Foo` is
/// unreachable from another file *by design*, and the suffix also catches
/// things that are not screens at all (`_RenderBlockShowOnScreen`).
final _screenClass = RegExp(
  r'^class\s+([A-Z][A-Za-z0-9_]*Screen)\b',
  multiLine: true,
);

List<File> _dartFilesUnder(String path) => Directory(path)
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'))
    .toList();

void main() {
  test('every *Screen is referenced from outside its own file', () {
    final libDir = Directory('lib');
    expect(libDir.existsSync(), isTrue,
        reason: 'run this from the mobile/ package root');

    final allFiles = _dartFilesUnder('lib');

    // className -> the file that declares it.
    final declaredIn = <String, String>{};
    for (final file in allFiles) {
      for (final m in _screenClass.allMatches(file.readAsStringSync())) {
        declaredIn[m.group(1)!] = file.path;
      }
    }
    expect(declaredIn, isNotEmpty,
        reason: 'found no screen classes — has the layout changed?');

    // Pre-read every file once; this runs over the whole package.
    final sources = {
      for (final f in allFiles) f.path: f.readAsStringSync(),
    };

    final unreferenced = <String, String>{};
    declaredIn.forEach((className, ownPath) {
      if (_allowedUnreferenced.containsKey(className)) return;
      // \b so FooScreen does not match FooScreenState, and so a bare mention
      // counts however it is reached — `const FooScreen()`, a static
      // `FooScreen.route(...)` factory (which is how QuizDeckScreen is opened),
      // or any other use.
      final mention = RegExp('\\b$className\\b');
      final referenced = sources.entries.any(
        (e) => e.key != ownPath && mention.hasMatch(e.value),
      );
      if (!referenced) unreferenced[className] = ownPath;
    });

    expect(
      unreferenced,
      isEmpty,
      reason: 'These screens are unreachable — nothing outside their own file '
          'names them, so no code path can open them. Either give each one an '
          'entry point, delete it, or add it to _allowedUnreferenced with a '
          'reason:\n'
          '${unreferenced.entries.map((e) => '  ${e.key}  (${e.value})').join('\n')}',
    );
  });

  test('the allowlist has no stale entries', () {
    final declared = <String>{};
    for (final file in _dartFilesUnder('lib')) {
      for (final m in _screenClass.allMatches(file.readAsStringSync())) {
        declared.add(m.group(1)!);
      }
    }
    final stale = _allowedUnreferenced.keys.where((c) => !declared.contains(c));
    expect(stale, isEmpty,
        reason: 'allowlisted screens that no longer exist: ${stale.join(', ')}');
  });
}
