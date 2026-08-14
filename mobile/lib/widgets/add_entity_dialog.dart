import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';

/// What the reviewer chose to add to a claim.
typedef AddedEntity = ({String name, String kind});

/// Add an item to a claim during graph-draft review — a concept OR an identity.
///
/// The review screen only ever offered "개념 추가", which made one real repair
/// impossible: when the extractor produced a wrong identity (an OCR typo, a
/// name read off a stray line), deleting it left no way to put the right one
/// back. The reviewer could add the person's name, but only ever as a Concept —
/// so a person ended up on the graph as a topic.
///
/// The draft model already carried both kinds ([kindPerson] renders through the
/// person chip and commits with a `new_person` resolution); only the entry point
/// was missing. This is that entry point, and it stays a SINGLE dialog with a
/// type toggle rather than a second button: the add affordance sits inside a
/// dense chip row where "추가" spelled out was already the widest thing in the
/// card.
///
/// Deliberately two options, not three. Person-vs-Source is a distinction the
/// draft's `kind` field cannot express — it is settled later, in the speaker
/// identity sheet, where `asSource` exists. Offering "출처" here would be
/// offering a value the commit path has nowhere to put.
const kindConcept = 'concept';
const kindPerson = 'person';

Future<AddedEntity?> showAddEntityDialog(BuildContext context) async {
  final controller = TextEditingController();
  final result = await showDialog<AddedEntity>(
    context: context,
    builder: (ctx) {
      var kind = kindConcept;
      return StatefulBuilder(
        builder: (ctx, setState) {
          void submit() {
            final name = controller.text.trim();
            if (name.isEmpty) return;
            Navigator.pop(ctx, (name: name, kind: kind));
          }

          return AlertDialog(
            title: Text(tr('graphReview.addEntityTitle')),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SegmentedButton<String>(
                  segments: [
                    ButtonSegment(
                      value: kindConcept,
                      icon: const Icon(Icons.tag_rounded, size: 16),
                      label: Text(tr('graphReview.addKindConcept')),
                    ),
                    ButtonSegment(
                      value: kindPerson,
                      icon: const Icon(Icons.person_outline_rounded, size: 16),
                      label: Text(tr('graphReview.addKindPerson')),
                    ),
                  ],
                  selected: {kind},
                  showSelectedIcon: false,
                  onSelectionChanged: (s) => setState(() => kind = s.first),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: controller,
                  autofocus: true,
                  decoration: InputDecoration(
                    hintText: kind == kindPerson
                        ? tr('graphReview.addPersonHint')
                        : tr('graphReview.addConceptHint'),
                  ),
                  onSubmitted: (_) => submit(),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(tr('common.cancel')),
              ),
              TextButton(onPressed: submit, child: Text(tr('common.add'))),
            ],
          );
        },
      );
    },
  );
  controller.dispose();
  return result;
}
