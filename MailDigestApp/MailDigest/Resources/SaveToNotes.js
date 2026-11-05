// SaveToNotes.js — appends HTML to the note named "Mail Digest" in Notes, creating it if it is missing.
// Usage: osascript -l JavaScript SaveToNotes.js '{"html":"<div>…</div>"}'
// The argument is JSON, never source text. The caller has already HTML-escaped all email text.
// Output: {"ok":true}. Apple Event errors (for example -1743, Automation denied) go to stderr.

function run(argv) {
  var input = JSON.parse(argv[0]);
  var html = String(input.html || '');
  if (html === '') return JSON.stringify({ ok: false, error: 'empty' });

  var title = 'Mail Digest';
  var Notes = Application('Notes');

  // An exact-name match anywhere, ignoring notes the user already deleted.
  var existing = null;
  var matches = Notes.notes.whose({ name: title })();
  for (var i = 0; i < matches.length; i++) {
    var folderName = '';
    try { folderName = matches[i].container().name(); } catch (e) {}
    if (folderName !== 'Recently Deleted') { existing = matches[i]; break; }
  }

  if (existing) {
    existing.body = existing.body() + html;
  } else {
    // Notes takes a note's name from the first line of its body.
    var note = Notes.Note({ body: '<div><h1>' + title + '</h1></div>' + html });
    Notes.defaultAccount().defaultFolder().notes.push(note);
  }
  return JSON.stringify({ ok: true });
}
