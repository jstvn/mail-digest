// FetchMail.js — JXA fallback for fetching message bodies from one mailbox (read-only).
// Usage: osascript -l JavaScript FetchMail.js '<json>'
//   json: {"accountID": "<UUID>" | null, "path": [...], "references": [{"messageID": "...", "storeRowID": 123 | null}]}
// Output: {"messages": [{id, storeRowID, account, mailbox, sender, subject, receivedAt, body, rawHeaders}],
//          "missing": ["<messageID>", ...]}
//
// Lookup (verified on the target Mac): `messages.byId(storeRowID)` resolves Mail's own id, which
// equals the Envelope Index ROWID. `whose({messageId: id})` misses messages that carry a
// Resent-Message-ID, because Mail's messageId property is the Resent value for them. Every
// candidate is accepted only if its raw Message-ID header equals the requested canonical ID.

function run(argv) {
  const args = JSON.parse(argv[0]);
  const Mail = Application('Mail');

  function isTopLevel(box) {
    try { return !box.container.name(); } catch (e) { return true; }
  }

  function resolveMailbox(accountID, path) {
    const roots = accountID === null ? Mail.mailboxes() : Mail.accounts.byId(accountID).mailboxes();
    const top = roots.filter(b => b.name() === path[0] && isTopLevel(b));
    if (top.length !== 1) throw new Error('Mailbox not found or ambiguous');
    let box = top[0];
    for (const name of path.slice(1)) box = box.mailboxes.byName(name);
    box.name();
    return box;
  }

  function canonical(raw) {
    const s = String(raw || '').replace(/\s+/g, ' ').trim();
    const m = /<([^<>]*)>/.exec(s);
    const v = (m ? m[1] : s).trim();
    return v && !/\s/.test(v) ? v : '';
  }

  function headerID(message) {
    const values = message.headers.whose({ name: 'message-id' }).content();
    return values.length === 1 ? canonical(values[0]) : '';
  }

  const box = resolveMailbox(args.accountID, args.path);
  const accountName = args.accountID === null ? 'On My Mac' : Mail.accounts.byId(args.accountID).name();

  function find(ref) {
    if (ref.storeRowID !== null && ref.storeRowID !== undefined) {
      try {
        const m = box.messages.byId(ref.storeRowID);
        if (headerID(m) === ref.messageID) return m;
      } catch (e) { /* moved, deleted or reindexed: try the ID lookup */ }
    }
    let verified = [];
    try {
      verified = box.messages.whose({ messageId: ref.messageID })().filter(m => headerID(m) === ref.messageID);
    } catch (e) { return null; }
    if (verified.length === 0) return null;
    // Same rule as listing (Q32): newest copy wins, Mail's order breaks ties.
    let best = verified[0];
    for (const m of verified.slice(1)) if (m.dateReceived() > best.dateReceived()) best = m;
    return best;
  }

  const messages = [], missing = [];
  for (const ref of args.references) {
    const m = find(ref);
    if (!m) { missing.push(ref.messageID); continue; }
    messages.push({
      id: ref.messageID,
      storeRowID: m.id(),
      account: accountName,
      mailbox: args.path.join('/'),
      sender: m.sender() || '',
      subject: m.subject() || '',
      receivedAt: m.dateReceived().toISOString(),
      body: m.content() || '',
      rawHeaders: m.allHeaders() || '',
    });
  }
  return JSON.stringify({ messages: messages, missing: missing });
}
