// ListMail.js — JXA fallback for listing message metadata in one mailbox (read-only).
// Usage: osascript -l JavaScript ListMail.js '<json>'
//   json: {"accountID": "<UUID>" | null (On My Mac), "path": ["Parent", "Child"], "from": <epoch ms>, "to": <epoch ms>}
// Output: JSON array, newest first, of {id, storeRowID, account, mailbox, sender, subject, receivedAt}
// for messages received in [from, to). `id` is the raw RFC Message-ID header ("" when absent).

function run(argv) {
  const args = JSON.parse(argv[0]);
  const Mail = Application('Mail');

  function isTopLevel(box) {
    try { return !box.container.name(); } catch (e) { return true; }
  }

  // Resolves a path top-down; the flat account list only carries leaf names, so a nested
  // mailbox could otherwise be confused with a top-level one of the same name.
  function resolveMailbox(accountID, path) {
    const roots = accountID === null ? Mail.mailboxes() : Mail.accounts.byId(accountID).mailboxes();
    const top = roots.filter(b => b.name() === path[0] && isTopLevel(b));
    if (top.length !== 1) throw new Error('Mailbox not found or ambiguous');
    let box = top[0];
    for (const name of path.slice(1)) box = box.mailboxes.byName(name);
    box.name(); // throws if the path no longer exists
    return box;
  }

  // First <...> token, else the trimmed value; mirrors MessageID.canonical in MailDigestCore.
  function canonical(raw) {
    const s = String(raw || '').replace(/\s+/g, ' ').trim();
    const m = /<([^<>]*)>/.exec(s);
    const v = (m ? m[1] : s).trim();
    return v && !/\s/.test(v) ? v : '';
  }

  const box = resolveMailbox(args.accountID, args.path);
  const accountName = args.accountID === null ? 'On My Mac' : Mail.accounts.byId(args.accountID).name();
  const msgs = box.messages;

  // One Apple Event per property for the whole mailbox. `messageId()` is not used: it returns
  // Resent-Message-ID when present, so the Message-ID header element is read instead.
  function readAll() {
    const ids = msgs.id();
    const r = {
      ids: ids,
      dates: msgs.dateReceived(),
      senders: msgs.sender(),
      subjects: msgs.subject(),
      headers: msgs.headers.whose({ name: 'message-id' }).content(),
    };
    // New mail arriving mid-read would shift the arrays; re-read the ids to prove alignment.
    const after = msgs.id();
    const n = ids.length;
    const aligned = [r.dates, r.senders, r.subjects, r.headers, after].every(a => a.length === n)
      && after.every((v, i) => v === ids[i]);
    return aligned ? r : null;
  }

  const data = readAll() || readAll();
  if (!data) throw new Error('Mailbox changed while listing; property arrays are not aligned');

  const from = Number(args.from), to = Number(args.to);
  const seen = new Set();
  const rows = [];
  for (let i = 0; i < data.ids.length; i++) {
    const d = data.dates[i];
    if (!d) continue;
    const t = d.getTime();
    if (t < from || t >= to) continue;
    const id = canonical(data.headers[i] && data.headers[i][0]);
    // Q32: Mail's collection is newest first, so the first occurrence of an id wins.
    if (id) {
      if (seen.has(id)) continue;
      seen.add(id);
    }
    rows.push({ order: rows.length, t: t, row: {
      id: id,
      storeRowID: data.ids[i],
      account: accountName,
      mailbox: args.path.join('/'),
      sender: data.senders[i] || '',
      subject: data.subjects[i] || '',
      receivedAt: d.toISOString(),
    } });
  }
  // Newest first; ties keep Mail's order.
  rows.sort((a, b) => (b.t - a.t) || (a.order - b.order));
  return JSON.stringify(rows.map(r => r.row));
}
