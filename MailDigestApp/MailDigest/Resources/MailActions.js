// MailActions.js — JXA mail actions: move to Trash, move to a folder, restore (undo), verify.
// Usage: osascript -l JavaScript MailActions.js '<json>'
//   json: {
//     "action": "trash" | "move" | "restore" | "verify",
//     "accountID": "<UUID>" | null,            // null = On My Mac
//     "path": ["Inbox"],                       // source mailbox (trash, move, verify)
//     "targetName": "Mail Digest",             // move only
//     "createIfMissing": true,                 // move only
//     "destinationPath": ["Trash"],            // restore only: where the messages are now
//     "restorePath": ["Inbox"],                // restore only: where they go back to
//     "references": [{"messageID": "<canonical>", "storeRowID": 123 | null}],
//     "budgetSeconds": 100                     // optional; stops starting new messages after this
//   }
// Output: {"results": [{messageID, account, originalMailbox, succeeded, error, destinationMailbox}]}
// One result per reference, in order. A failure on one message never aborts the others.
//
// Safety: nothing here deletes anything. Messages are only ever moved between mailboxes of the same
// account (Mail's `move`); there is no `delete`, no emptying of Trash and no mailbox deletion.
//
// Lookup follows Q29 and FetchMail.js: `messages.byId(storeRowID)` first (Mail's own id equals the
// Envelope Index ROWID), then `whose({messageId})`. A message is acted on only if its raw Message-ID
// header equals the requested canonical ID, and only if exactly one such message is found.
// Logging: this script prints nothing but the JSON result; no subjects or bodies are read.

function run(argv) {
  const args = JSON.parse(argv[0]);
  const Mail = Application('Mail');
  const deadline = Date.now() + (args.budgetSeconds || 100) * 1000;
  const ERR = {
    notFound: 'not found',
    ambiguous: 'ambiguous',
    notRunning: "Mail isn't running",
    denied: 'Mail automation denied',
    time: 'not attempted (time limit)',
  };

  // A top-level mailbox's container is its account, whose name() is null (or throws).
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

  // The nested path of a mailbox, e.g. ["[Gmail]", "Trash"].
  function pathOf(box) {
    const names = [box.name()];
    let c = box.container;
    for (let i = 0; i < 20; i++) {
      let n = null;
      try { n = c.name(); } catch (e) { n = null; }
      if (!n) break;
      names.unshift(n);
      c = c.container;
    }
    return names;
  }

  function canonical(raw) {
    const s = String(raw || '').replace(/\s+/g, ' ').trim();
    const m = /<([^<>]*)>/.exec(s);
    const v = (m ? m[1] : s).trim();
    return v && !/\s/.test(v) ? v : '';
  }

  function headerID(message) {
    try {
      const values = message.headers.whose({ name: 'message-id' }).content();
      return values.length === 1 ? canonical(values[0]) : '';
    } catch (e) { return ''; }
  }

  // Short, content-free error text. Never include Mail's own message (it can quote subjects).
  function errorText(e) {
    const text = String((e && e.message) || e);
    if (text.indexOf('-1743') >= 0) return ERR.denied;
    if (text.indexOf('-600') >= 0 || text.indexOf("isn't running") >= 0) return ERR.notRunning;
    if (text === ERR.notFound || text === ERR.ambiguous) return text;
    if (/^(already in |no Trash|no target|couldn't create|Mailbox not found)/.test(text)) return text;
    return 'Mail error';
  }

  // Finds the one verified message for a reference inside `box`: {message} or {error}.
  function find(box, ref) {
    if (ref.storeRowID !== null && ref.storeRowID !== undefined) {
      try {
        const m = box.messages.byId(ref.storeRowID);
        if (headerID(m) === ref.messageID) return { message: m };
      } catch (e) { /* moved, deleted or reindexed: fall back to the ID lookup */ }
    }
    let verified;
    try {
      verified = box.messages.whose({ messageId: ref.messageID })().filter(m => headerID(m) === ref.messageID);
    } catch (e) { return { error: ERR.notFound }; }
    if (verified.length === 0) return { error: ERR.notFound };
    if (verified.length > 1) return { error: ERR.ambiguous };
    return { message: verified[0] };
  }

  // Mail's Trash mailboxes, one per account (and a local one); identified by Mail, never by name.
  let trashCache = null;
  function trashBoxes() {
    if (trashCache) return trashCache;
    trashCache = [];
    for (const b of Mail.trashMailbox.mailboxes()) {
      let id = null;
      try { id = b.account().id(); } catch (e) { id = null; }
      trashCache.push({ box: b, accountID: id, path: pathOf(b) });
    }
    return trashCache;
  }

  function isTrashBox(accountID, path) {
    const key = path.join('\u0000');
    return trashBoxes().some(t => t.accountID === accountID && t.path.join('\u0000') === key);
  }

  function trashTarget(accountID) {
    const hits = trashBoxes().filter(t => t.accountID === accountID);
    if (hits.length !== 1) throw new Error('no Trash mailbox for this account');
    return hits[0].box;
  }

  function moveTarget() {
    const lookup = () => {
      const roots = args.accountID === null ? Mail.mailboxes() : Mail.accounts.byId(args.accountID).mailboxes();
      return roots.filter(b => b.name() === args.targetName && isTopLevel(b));
    };
    let hits = lookup();
    if (hits.length === 1) return hits[0];
    if (hits.length > 1) throw new Error('no target: more than one mailbox has that name');
    if (!args.createIfMissing) throw new Error('no target mailbox');
    try {
      if (args.accountID === null) {
        Mail.make({ new: 'mailbox', withProperties: { name: args.targetName } });
      } else {
        Mail.make({ new: 'mailbox', withProperties: { name: args.targetName }, at: Mail.accounts.byId(args.accountID) });
      }
    } catch (e) { throw new Error("couldn't create the mailbox"); }
    hits = lookup();
    if (hits.length !== 1) throw new Error("couldn't create the mailbox");
    return hits[0];
  }

  const accountName = args.accountID === null ? 'On My Mac' : Mail.accounts.byId(args.accountID).name();
  const originalName = (args.action === 'restore' ? args.restorePath : args.path).join('/');
  const results = [];
  function record(ref, succeeded, error, destination) {
    results.push({
      messageID: ref.messageID,
      account: accountName,
      originalMailbox: originalName,
      succeeded: succeeded,
      error: succeeded ? null : error,
      destinationMailbox: succeeded ? (destination || null) : null,
    });
  }

  function failAll(text) {
    for (const ref of args.references) record(ref, false, text, null);
    return JSON.stringify({ results: results });
  }

  // ---- restore (undo) ----
  if (args.action === 'restore') {
    let from, to;
    try {
      from = resolveMailbox(args.accountID, args.destinationPath);
      to = resolveMailbox(args.accountID, args.restorePath);
    } catch (e) { return failAll(errorText(e)); }

    // A moved message has a new id, so search the destination. Bounded scan of the newest messages
    // is the fallback when the `whose` lookup misses (it can't see Resent-Message-ID messages).
    let scan = null;
    function scanIndex() {
      if (scan) return scan;
      scan = {};
      const newest = from.messages().slice(0, 500);
      for (const m of newest) {
        if (Date.now() > deadline) break;
        const id = headerID(m);
        if (id) (scan[id] = scan[id] || []).push(m);
      }
      return scan;
    }

    for (const ref of args.references) {
      if (Date.now() > deadline) { record(ref, false, ERR.time, null); continue; }
      try {
        let verified = [];
        try {
          verified = from.messages.whose({ messageId: ref.messageID })().filter(m => headerID(m) === ref.messageID);
        } catch (e) { verified = []; }
        if (verified.length === 0) verified = scanIndex()[ref.messageID] || [];
        if (verified.length === 0) { record(ref, false, ERR.notFound, null); continue; }
        if (verified.length > 1) { record(ref, false, ERR.ambiguous, null); continue; }
        Mail.move(verified[0], { to: to });
        record(ref, true, null, args.restorePath.join('/'));
      } catch (e) { record(ref, false, errorText(e), null); }
    }
    return JSON.stringify({ results: results });
  }

  // ---- trash, move, verify: all start from the source mailbox ----
  let box;
  try { box = resolveMailbox(args.accountID, args.path); } catch (e) { return failAll(errorText(e)); }

  const sourceIsTrash = args.action !== 'verify' && isTrashBox(args.accountID, args.path);
  let target = null, targetError = null;

  for (const ref of args.references) {
    if (Date.now() > deadline) { record(ref, false, ERR.time, null); continue; }
    try {
      const found = find(box, ref);
      if (!found.message) { record(ref, false, found.error, null); continue; }
      if (args.action === 'verify') { record(ref, true, null, null); continue; }
      if (sourceIsTrash) throw new Error('already in Trash');

      if (!target && !targetError) {
        try {
          target = args.action === 'trash' ? trashTarget(args.accountID) : moveTarget();
        } catch (e) { targetError = errorText(e); }
      }
      if (!target) { record(ref, false, targetError, null); continue; }
      const destination = pathOf(target);
      if (args.action === 'move' && destination.join('\u0000') === args.path.join('\u0000')) {
        throw new Error('already in ' + args.targetName);
      }
      Mail.move(found.message, { to: target });
      record(ref, true, null, destination.join('/'));
    } catch (e) { record(ref, false, errorText(e), null); }
  }
  return JSON.stringify({ results: results });
}
