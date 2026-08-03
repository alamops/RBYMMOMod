'use strict';

/*
 * What address should the host hand to a friend?
 *
 * **No third-party network calls, ever.** Every fact below comes from
 * os.networkInterfaces() -- this machine describing itself -- and, only when
 * the host has explicitly turned UPnP on, from their own router. There is no
 * STUN, no "what is my IP" service, no port-check service, no telemetry. This
 * is software whose entire selling point is that it is safe to run and safe to
 * connect to; a self-check that quietly phoned a stranger to ask about the
 * host's network would undercut exactly that, and a host who noticed would be
 * right to stop trusting the rest of it.
 *
 * The cost of that choice is honest: local interfaces cannot tell you whether
 * a router in front of the machine forwards the port. So this module never
 * claims reachability it cannot see. When nothing public is bound it says
 * plainly that friends outside the network will not reach the port, and names
 * the three fixes -- because a host who believes they are reachable and is not
 * will blame the game, not their router.
 *
 * No dependencies: node:os only.
 */

const os = require('node:os');

// The four labels. Anything that is not clearly one of the first three is
// public -- with one deliberate exception, below.
const LOOPBACK = 'loopback';
const PRIVATE = 'private';
const CGNAT = 'cgnat';
const PUBLIC = 'public';

const DESCRIPTIONS = {
  [LOOPBACK]: 'loopback (this machine only)',
  [PRIVATE]: 'private network',
  [CGNAT]: 'carrier-grade NAT or overlay network',
  [PUBLIC]: 'public address',
};

// ------------------------------------------------------------ classification

function classifyIpv4(address) {
  const parts = address.split('.');
  if (parts.length !== 4) return PRIVATE; // see the note below
  const octets = parts.map((part) => Number.parseInt(part, 10));
  if (octets.some((n) => !Number.isInteger(n) || n < 0 || n > 255)) {
    // An address this module cannot parse is reported as *not* public. That
    // direction is chosen on purpose: guessing "public" would tell a host they
    // are reachable when nothing checked, which is the one failure mode this
    // file exists to prevent. Guessing "private" at worst tells them to
    // forward a port they did not need to.
    return PRIVATE;
  }

  const [a, b] = octets;
  if (a === 127) return LOOPBACK;
  if (a === 10) return PRIVATE;
  if (a === 172 && b >= 16 && b <= 31) return PRIVATE;
  if (a === 192 && b === 168) return PRIVATE;
  if (a === 169 && b === 254) return PRIVATE; // link-local, RFC 3927
  if (a === 100 && b >= 64 && b <= 127) return CGNAT; // 100.64.0.0/10, RFC 6598
  if (a === 0) return PRIVATE; // "this network"; never shareable
  if (a >= 224) return PRIVATE; // multicast and reserved; never a host address
  return PUBLIC;
}

function classifyIpv6(address) {
  const lower = address.toLowerCase();
  if (lower === '::1' || lower === '::') return LOOPBACK;

  // ::ffff:1.2.3.4 and the deprecated ::1.2.3.4 form both describe an IPv4
  // address wearing an IPv6 coat; classify what they actually are.
  if (lower.startsWith('::ffff:') || (lower.startsWith('::') && lower.includes('.'))) {
    const tail = lower.startsWith('::ffff:') ? lower.slice(7) : lower.slice(2);
    if (tail.includes('.')) return classifyIpv4(tail);
  }

  const head = Number.parseInt(lower.split(':')[0] || '0', 16);
  if (!Number.isInteger(head)) return PRIVATE; // unparseable: conservative, as above
  if ((head & 0xfe00) === 0xfc00) return PRIVATE; // fc00::/7 unique-local
  if ((head & 0xffc0) === 0xfe80) return PRIVATE; // fe80::/10 link-local
  if ((head & 0xff00) === 0xff00) return PRIVATE; // ff00::/8 multicast
  return PUBLIC;
}

function classifyAddress(address, family) {
  if (typeof address !== 'string' || !address) return PRIVATE;
  const isV6 = family === 'IPv6' || family === 6 || address.includes(':');
  return isV6 ? classifyIpv6(address) : classifyIpv4(address);
}

/**
 * Link-local (fe80::/10, 169.254/16) is an address a machine gives itself when
 * nothing else told it what to be. Every interface has one, they are all
 * useless to share, and on a laptop with a handful of VPN tunnels there are
 * more of them than real addresses -- so the report hides them rather than
 * burying the one line the host needed.
 */
function isLinkLocal(address, family) {
  if (typeof address !== 'string') return false;
  const isV6 = family === 'IPv6' || family === 6 || address.includes(':');
  if (isV6) {
    const head = Number.parseInt(address.toLowerCase().split(':')[0] || '0', 16);
    return Number.isInteger(head) && (head & 0xffc0) === 0xfe80;
  }
  return address.startsWith('169.254.');
}

/**
 * Every address this machine holds, labelled.
 *
 * Returns a flat array of
 *   { name, address, family: 'IPv4' | 'IPv6', scope, description, internal, cidr }
 * sorted so the addresses a host is most likely to share come first -- public,
 * then cgnat/overlay, then private, then loopback -- because the first line of
 * a report is the one people read.
 */
function classify(options = {}) {
  const source = typeof options.interfaces === 'function'
    ? options.interfaces
    : os.networkInterfaces;

  let table;
  try {
    table = source();
  } catch (err) {
    // A machine that will not describe its own interfaces is not a reason to
    // fail a command; report nothing and let the caller say so.
    return [];
  }

  const out = [];
  for (const [name, entries] of Object.entries(table || {})) {
    for (const entry of entries || []) {
      const family = entry.family === 6 || entry.family === 'IPv6' ? 'IPv6' : 'IPv4';
      const scope = classifyAddress(entry.address, family);
      out.push({
        name,
        address: entry.address,
        family,
        scope,
        description: DESCRIPTIONS[scope],
        linkLocal: isLinkLocal(entry.address, family),
        internal: entry.internal === true,
        cidr: entry.cidr || null,
      });
    }
  }

  const rank = { [PUBLIC]: 0, [CGNAT]: 1, [PRIVATE]: 2, [LOOPBACK]: 3 };
  out.sort((a, b) => {
    if (rank[a.scope] !== rank[b.scope]) return rank[a.scope] - rank[b.scope];
    if (a.family !== b.family) return a.family === 'IPv4' ? -1 : 1;
    return a.name.localeCompare(b.name);
  });
  return out;
}

// ---------------------------------------------------------------- reporting

function pick(interfaces, scope, family) {
  return interfaces.find((entry) => entry.scope === scope &&
    (!family || entry.family === family));
}

function shareable(address, port) {
  // A bare IPv6 address followed by :port is ambiguous, so bracket it -- the
  // form the player types in game is host:port either way.
  return address.includes(':') ? `[${address}]:${port}` : `${address}:${port}`;
}

function bindNote(host, interfaces) {
  const bound = typeof host === 'string' ? host.trim() : '';
  if (!bound || bound === '0.0.0.0' || bound === '::' || bound === '*') {
    return 'Bound to every address on this machine.';
  }
  const scope = classifyAddress(bound, bound.includes(':') ? 'IPv6' : 'IPv4');
  if (scope === LOOPBACK) {
    return `Bound to ${bound} only, which is this machine talking to itself: ` +
      'nobody else can connect, not even on this network. Set listen.host to ' +
      '0.0.0.0 to accept connections.';
  }
  const known = interfaces.some((entry) => entry.address === bound);
  return `Bound to ${bound} only` + (known
    ? '; connections to this machine\'s other addresses are refused.'
    : ', which is not an address this machine currently holds -- the hub will ' +
      'fail to bind until it is.');
}

/**
 * The lines to print. Returns an array of strings; the caller joins them.
 *
 * `external` is optional and only ever comes from the host's own router via
 * UPnP (see the header) -- never from a third party.
 */
function summary(options = {}) {
  const port = Number(options.port) || 7788;
  const host = options.host;
  const interfaces = Array.isArray(options.interfaces) ? options.interfaces : classify();
  const external = typeof options.external === 'string' && options.external
    ? options.external
    : null;

  const lines = [];
  lines.push('Reachability');

  if (interfaces.length === 0) {
    lines.push('  This machine reports no network interfaces at all, which is ' +
      'unusual enough that nothing below can be trusted.');
    return lines;
  }

  // Link-local addresses are hidden by default; on a laptop with VPN tunnels
  // they outnumber the real ones ten to one and none of them is shareable.
  const shown = interfaces.filter((entry) => !entry.linkLocal);
  const listed = shown.length ? shown : interfaces;
  const hidden = interfaces.length - listed.length;

  const width = Math.max(...listed.map((entry) => entry.name.length), 4);
  lines.push('  Addresses on this machine:');
  for (const entry of listed) {
    lines.push(`    ${entry.name.padEnd(width)}  ${entry.address.padEnd(39)}  ${entry.description}`);
  }
  if (hidden > 0) {
    lines.push(`    (${hidden} link-local address(es) not shown: nothing can be shared with them)`);
  }

  lines.push('');
  lines.push(`  ${bindNote(host, interfaces)}`);
  lines.push('');

  const publicV4 = pick(interfaces, PUBLIC, 'IPv4');
  const publicV6 = shown.find((entry) => entry.scope === PUBLIC && entry.family === 'IPv6');
  const cgnatEntry = pick(interfaces, CGNAT);
  const privateV4 = pick(interfaces, PRIVATE, 'IPv4');

  if (publicV4) {
    lines.push(`  Share this with friends anywhere:  ${shareable(publicV4.address, port)}`);
    lines.push('  That address is publicly routable. A firewall on this machine, or');
    lines.push('  one in front of it, can still block the port -- this check can see');
    lines.push('  the address, not the path to it.');
  } else {
    if (privateV4) {
      lines.push(`  Share this with friends on this network:  ${shareable(privateV4.address, port)}`);
    }
    if (cgnatEntry) {
      lines.push(`  Overlay or carrier address:  ${shareable(cgnatEntry.address, port)}`);
      lines.push('  100.64.0.0/10 is used both by ISP carrier-grade NAT and by overlay');
      lines.push('  networks such as Tailscale. If it came from an overlay, friends on');
      lines.push('  the same overlay can use it. If it came from your ISP, nobody can.');
    }
    if (publicV6) {
      lines.push(`  Public IPv6 address:  ${shareable(publicV6.address, port)}`);
      lines.push('  That one is routable without any port forwarding, but only for a');
      lines.push('  friend whose own network has IPv6 -- plenty still do not -- and');
      lines.push('  most routers firewall inbound IPv6 by default, so it usually needs');
      lines.push('  a pinhole for this port before anything arrives.');
    }
    lines.push('');
    // Stated flatly, on purpose. A softer "you may not be reachable" gets read
    // as "probably fine", and the host finds out when a friend cannot connect
    // and blames the game rather than the router.
    lines.push('  This machine has no public IPv4 address, so friends outside this');
    lines.push('  network will NOT reach this port over IPv4 as things stand. Three');
    lines.push('  ways to fix that:');
    lines.push('');
    lines.push(`    1. Forward TCP port ${port} on your router to ` +
      `${privateV4 ? privateV4.address : 'this machine'}.`);
    lines.push('       The router can be asked to do that automatically:');
    lines.push('       `rby-mmo-hub upnp enable` (read the warning it prints first).');
    lines.push('    2. Run the hub on a machine that already has a public address --');
    lines.push('       any small VPS will do, and it need not be powerful.');
    lines.push('    3. Put everyone on an overlay network (Tailscale, WireGuard,');
    lines.push('       ZeroTier) and share the overlay address instead. This is also');
    lines.push('       the only option that encrypts the traffic.');
  }

  if (external) {
    lines.push('');
    lines.push(`  Your router reports its external address as ${external}.`);
    if (!publicV4) {
      lines.push(`  With a forwarded port, friends would use ${shareable(external, port)}.`);
    }
  }

  return lines;
}

module.exports = {
  LOOPBACK,
  PRIVATE,
  CGNAT,
  PUBLIC,
  DESCRIPTIONS,
  classify,
  classifyAddress,
  isLinkLocal,
  summary,
  shareable,
};
