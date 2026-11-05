// CheckMail.js — asks Mail to fetch new mail for every account.
// Usage: osascript -l JavaScript CheckMail.js
// Output: {} on success; Apple Event errors (for example -1743, Automation denied) go to stderr.

function run() {
  Application('Mail').checkForNewMail();
  return JSON.stringify({});
}
