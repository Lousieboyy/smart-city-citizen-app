/// Presentation helpers for report text.
library;

/// Bookkeeping markers older builds appended to the description field before
/// upvotes had a column of their own.
final _legacyCountMarkers = RegExp(r'\s*\[(Upvote count|Urgent Flags):\s*\d+\]');

/// Strip internal bookkeeping out of a citizen's description.
///
/// The upvote total lives in the report's own `upvotes` field and is rendered
/// as a button, so "[Upvote count: 1]" showing up inside the description is
/// noise the reporter never wrote. The backend removes it whenever a report is
/// upvoted, but reports that have not been touched since still carry it — so
/// clean it on the way to the screen as well, and no data migration is needed.
String cleanDescription(Object? description) {
  final text = (description ?? '').toString();
  if (text.isEmpty) return text;
  return text.replaceAll(_legacyCountMarkers, '').trim();
}
