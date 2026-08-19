/// Correctness of a graded quiz result, whatever produced it.
///
/// The backend's submit response carries `correct` (see QuizSubmitResponse).
/// The cloze composer path grades locally and injects `is_correct` into the
/// same feedback map instead. Reading only one of the two keys is what made a
/// perfectly ordered scramble render as "Incorrect": the card asked for
/// `is_correct`, which the server never sends.
bool quizResultIsCorrect(Map<String, dynamic>? result) {
  if (result == null) return false;
  return result['is_correct'] == true || result['correct'] == true;
}
