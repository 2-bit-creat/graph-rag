class VocabularySummary {
  VocabularySummary({
    required this.id,
    required this.name,
    this.description = '',
    this.createdAt,
    this.wordCount = 0,
    this.isDefault = false,
    this.isSystem = false,
    this.language = 'english',
  });

  final String id;
  final String name;
  final String description;
  final String? createdAt;
  final int wordCount;
  final bool isDefault;
  final bool isSystem;
  /// "english", "german", etc. — used to filter vocab by selected quiz language.
  final String language;

  factory VocabularySummary.fromJson(Map<String, dynamic> json) {
    // Infer language from id if not explicitly provided
    String lang = json['language']?.toString() ?? '';
    if (lang.isEmpty) {
      final id = json['id']?.toString() ?? '';
      if (id.startsWith('statement_bank:')) {
        lang = id.substring('statement_bank:'.length);
      } else if (id.startsWith('default:')) {
        lang = id.substring('default:'.length);
      } else {
        lang = 'english';
      }
    }
    return VocabularySummary(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      description: json['description']?.toString() ?? '',
      createdAt: json['created_at']?.toString(),
      wordCount: json['word_count'] is num ? (json['word_count'] as num).toInt() : 0,
      isDefault: json['is_default'] == true,
      isSystem: json['is_system'] == true,
      language: lang,
    );
  }
}

class VocabWord {
  VocabWord({
    required this.word,
    required this.meaning,
    this.addedAt,
    this.reviewCount = 0,
    this.linkedDiaryId,
    this.expression,
    this.meaningKo,
    this.example,
    this.sourceNodeId,
    this.sourceNodeName,
  });

  final String word;
  final String meaning;
  final String? addedAt;
  final int reviewCount;
  final String? linkedDiaryId;

  // Statement bank fields
  final String? expression;
  final String? meaningKo;
  final String? example;
  final String? sourceNodeId;
  final String? sourceNodeName;

  bool get isStatementExpression => sourceNodeId != null && sourceNodeId!.isNotEmpty;

  factory VocabWord.fromJson(Map<String, dynamic> json) {
    return VocabWord(
      word: json['word']?.toString() ?? json['expression']?.toString() ?? '',
      meaning: json['meaning']?.toString() ?? json['meaning_ko']?.toString() ?? '',
      addedAt: json['added_at']?.toString(),
      reviewCount: json['review_count'] is num ? (json['review_count'] as num).toInt() : 0,
      linkedDiaryId: json['linked_diary_id']?.toString(),
      expression: json['expression']?.toString(),
      meaningKo: json['meaning_ko']?.toString(),
      example: json['example_en']?.toString() ?? json['example']?.toString(),
      sourceNodeId: json['source_node_id']?.toString(),
      sourceNodeName: json['source_node_name']?.toString(),
    );
  }
}

/// Expression extracted from a Statement node for a specific language.
class NodeExpression {
  NodeExpression({
    required this.expression,
    required this.meaning,
    this.example,
    this.addedAt,
  });

  final String expression;
  final String meaning;
  final String? example;
  final String? addedAt;

  factory NodeExpression.fromJson(Map<String, dynamic> json) {
    return NodeExpression(
      expression: json['expression']?.toString() ?? '',
      meaning: json['meaning']?.toString() ?? json['meaning_ko']?.toString() ?? '',
      example: json['example']?.toString() ?? json['example_en']?.toString(),
      addedAt: json['added_at']?.toString(),
    );
  }
}
