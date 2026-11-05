// ListMailboxes.js — JXA fallback for listing every account's mailboxes (read-only).
// Usage: osascript -l JavaScript ListMailboxes.js
// Output: JSON array of {account, accountID, name, kind, messageCount, unreadCount}.
// `name` is the full nested path joined with "/"; On My Mac mailboxes have accountID null.

function run() {
  const Mail = Application('Mail');

  // A top-level mailbox's container is its account, which JXA cannot coerce: `container.name()`
  // returns null (or throws), while a nested mailbox returns its parent's name.
  function isTopLevel(box) {
    try { return !box.container.name(); } catch (e) { return true; }
  }

  // Walks the hierarchy top-down because the flat account list only carries leaf names.
  function walk(box, prefix, visit) {
    const path = prefix.concat([box.name()]);
    visit(box, path);
    for (const child of box.mailboxes()) walk(child, path, visit);
  }

  // Kinds come from Mail's special mailboxes, never from (localised) names.
  const kinds = {};
  const specials = [['inbox', 'inbox'], ['sentMailbox', 'sent'], ['draftsMailbox', 'drafts'],
                    ['junkMailbox', 'junk'], ['trashMailbox', 'trash']];
  for (const [property, kind] of specials) {
    for (const box of Mail[property].mailboxes()) {
      try { kinds[box.account().id() + '\u0000' + box.name()] = kind; } catch (e) { /* no account */ }
    }
  }

  const out = [];
  function emit(box, path, accountName, accountID) {
    const key = accountID === null ? null : accountID + '\u0000' + path.join('/');
    out.push({
      account: accountName,
      accountID: accountID,
      name: path.join('/'),
      kind: (key !== null && path.length === 1 && kinds[key]) || 'custom',
      messageCount: box.messages.length,
      unreadCount: box.unreadCount(),
    });
  }

  for (const account of Mail.accounts()) {
    const accountID = account.id();
    const accountName = account.name();
    for (const box of account.mailboxes()) {
      if (!isTopLevel(box)) continue;
      walk(box, [], (b, path) => emit(b, path, accountName, accountID));
    }
  }

  // On My Mac mailboxes are application-level, not account children.
  for (const box of Mail.mailboxes()) {
    if (!isTopLevel(box)) continue;
    walk(box, [], (b, path) => emit(b, path, 'On My Mac', null));
  }

  return JSON.stringify(out);
}
