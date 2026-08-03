'use strict';

/*
 * Levelled logging that a hostile peer cannot write into.
 *
 * The hub logs things it was told by strangers -- trainer names, error
 * strings from parsing their input -- straight onto the host's terminal.
 * Interpolating those raw is how a name containing a newline forges a log
 * line, and how one containing an ANSI escape repaints somebody's console.
 * Every untrusted value therefore goes through safe(), and the composed
 * line is stripped a second time so a caller who forgets still cannot make
 * the logger emit a control byte.
 */

const LEVELS = { error: 0, warn: 1, info: 2, debug: 3 };

// Order matters: ANSI sequences start with ESC, so they have to be matched
// as sequences before the control-character sweep eats the ESC and leaves
// the "[31m" behind as visible text.
const ANSI = /\u001b\[[0-9;?]*[ -\/]*[@-~]/g;
const CONTROL = /[\u0000-\u001f\u007f-\u009f]/g;

const VALUE_MAX = 120;

function strip(text) {
  return text.replace(ANSI, '').replace(CONTROL, ' ');
}

// Render one untrusted value for a log line: flattened, bounded, quoted.
// Quoting is JSON's, so the quotes and backslashes inside the value are
// escaped rather than closing the quoting early.
function safe(value) {
  let text;
  try {
    if (typeof value === 'string') text = value;
    else if (value !== null && typeof value === 'object') text = JSON.stringify(value);
    else text = String(value);
  } catch (err) {
    text = '<unprintable>';
  }
  if (typeof text !== 'string') text = '<unprintable>';
  text = strip(text);
  if (text.length > VALUE_MAX) text = text.slice(0, VALUE_MAX - 3) + '...';
  return JSON.stringify(text);
}

function createLog(options) {
  const opts = options || {};
  const name = LEVELS[opts.level] === undefined ? 'info' : opts.level;
  const threshold = LEVELS[name];
  const stream = opts.stream || process.stdout;

  const write = (level, message) => {
    if (LEVELS[level] > threshold) return;
    const line = new Date().toISOString() + ' ' + level.toUpperCase() + ' ' +
      strip(String(message)) + '\n';
    // A closed pipe (the host piped us into `head`) must not take the hub
    // down; losing a log line is the cheaper failure.
    try {
      stream.write(line);
    } catch (err) {
      /* nothing useful can be logged about a broken log */
    }
  };

  return {
    level: name,
    error: (message) => write('error', message),
    warn: (message) => write('warn', message),
    info: (message) => write('info', message),
    debug: (message) => write('debug', message),
  };
}

module.exports = { createLog, safe, LEVELS };
