'use strict';

/*
 * Opt-in automatic port forwarding, off by default.
 *
 * Asking the router to open a port is the difference between "my friends
 * cannot connect" and a working hub, for a host who cannot or will not log
 * into a router admin page. That is why it ships. It is also, by a wide
 * margin, the largest deliberate risk in this feature, so it ships as an
 * explicit verb (`rby-mmo-hub upnp enable`), never as a default, never
 * silently, and never without the warning the CLI prints first: most home
 * routers accept these requests from anything on the LAN with no
 * authentication whatsoever, which means the IoT plug and the guest laptop
 * can open ports the same way. A leased mapping expires on its own, and
 * `upnp disable` removes it explicitly.
 *
 * The only remote party this file ever talks to is the host's own router,
 * discovered by multicast on the local link. No third-party service is
 * contacted here or anywhere else in this software.
 *
 * Nothing below throws. A router that does not answer, answers with junk, or
 * answers with a SOAP fault is an ordinary Tuesday on a home network, not a
 * crash -- every export resolves to a result object carrying `ok`, so a
 * failure can never take the hub down or abort a CLI verb halfway.
 *
 * XML is matched, not parsed. The response comes from an unauthenticated
 * device on the LAN and may be truncated, mis-encoded or hostile, so this
 * reads a handful of known tags out of a size-capped string with bounded
 * regexes. Writing a general XML parser to talk to one device would be a
 * larger attack surface than the thing it is parsing.
 *
 * No dependencies: node:dgram, node:http, node:os.
 */

const dgram = require('node:dgram');
const http = require('node:http');
const os = require('node:os');

const SSDP_ADDRESS = '239.255.255.250';
const SSDP_PORT = 1900;
const SSDP_TARGET = 'urn:schemas-upnp-org:device:InternetGatewayDevice:1';

// The two services that can actually forward a port: IP for cable/fibre,
// PPP for DSL. Preference order, first match wins.
const WAN_SERVICES = [
  'urn:schemas-upnp-org:service:WANIPConnection:2',
  'urn:schemas-upnp-org:service:WANIPConnection:1',
  'urn:schemas-upnp-org:service:WANPPPConnection:1',
];

// Caps. A device description is a few kilobytes; anything past this is either
// broken or trying to make us hold it in memory.
const MAX_BODY_BYTES = 128 * 1024;
const HTTP_TIMEOUT_MS = 5000;

const DESCRIPTION_MAX = 60;
const LEASE_MAX = 604800;

// UPnP error codes worth translating. The rest are reported by number, which
// is more useful than a wrong guess at what a vendor meant by 501.
const ERRORS = {
  401: 'the router does not support this action',
  402: 'the router rejected the request as malformed (invalid args)',
  501: 'the router tried and failed (action failed)',
  606: 'the router requires authentication for port mappings',
  714: 'no such mapping exists',
  715: 'the router will not accept a wildcard source address',
  716: 'the router will not accept a wildcard external port',
  718: 'that external port is already mapped to a different machine',
  724: 'the router requires the internal and external ports to match',
  725: 'the router only supports permanent leases',
  727: 'the router requires a specific external port',
};

// ------------------------------------------------------------------ helpers

function fail(error, extra) {
  return Object.assign({ ok: false, error: String(error) }, extra || {});
}

function xmlEscape(value) {
  return String(value)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&apos;');
}

/** First value of <tag>...</tag>, bounded and untrimmed of nothing else. */
function tagValue(xml, tag) {
  const match = new RegExp(`<(?:[a-zA-Z0-9_-]+:)?${tag}\\b[^>]*>([\\s\\S]{0,512}?)<`, 'i').exec(xml);
  if (!match) return null;
  return match[1]
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&amp;/g, '&')
    .trim();
}

function clampPort(value) {
  const n = Math.floor(Number(value));
  if (!Number.isFinite(n) || n < 1 || n > 65535) return null;
  return n;
}

function clampLease(value) {
  const n = Math.floor(Number(value));
  if (!Number.isFinite(n) || n < 0) return 3600;
  return Math.min(LEASE_MAX, n);
}

/** First non-loopback IPv4 this machine holds; right on any single-homed host. */
function firstLocalIpv4() {
  try {
    for (const entries of Object.values(os.networkInterfaces() || {})) {
      for (const entry of entries || []) {
        const family = entry.family === 4 || entry.family === 'IPv4';
        if (family && !entry.internal) return entry.address;
      }
    }
  } catch (err) {
    /* nothing to offer */
  }
  return null;
}

/**
 * Which of this machine's addresses the router should forward *to*.
 *
 * Derived by opening a UDP socket "connected" to the router and reading back
 * the local address the kernel picked -- the only way to get the right answer
 * on a machine with several interfaces. connect() on a datagram socket sends
 * no packet, it only fixes the route, so this costs nothing and reaches
 * nobody. Anything unexpected falls back to the interface scan.
 */
function localAddressFor(routerAddress) {
  return new Promise((resolve) => {
    if (!routerAddress) {
      resolve(firstLocalIpv4());
      return;
    }

    let socket;
    try {
      socket = dgram.createSocket('udp4');
    } catch (err) {
      resolve(firstLocalIpv4());
      return;
    }

    const done = (address) => {
      try { socket.close(); } catch (err) { /* already closed */ }
      resolve(address || firstLocalIpv4());
    };

    socket.on('error', () => done(null));
    const timer = setTimeout(() => done(null), 500);
    if (timer.unref) timer.unref();

    try {
      socket.connect(SSDP_PORT, routerAddress, () => {
        clearTimeout(timer);
        let address = null;
        try {
          address = socket.address().address;
        } catch (err) {
          address = null;
        }
        done(address === '0.0.0.0' ? null : address);
      });
    } catch (err) {
      clearTimeout(timer);
      done(null);
    }
  });
}

// ---------------------------------------------------------------- discovery

/**
 * SSDP M-SEARCH for an Internet Gateway Device, then fetch and read its
 * description to find a control URL that can forward ports.
 *
 * Resolves { ok, controlUrl, serviceType, location, router, localAddress } or
 * { ok: false, error }. Never rejects.
 */
async function discover(options = {}) {
  const timeoutMs = Math.max(500, Math.min(30000, Number(options.timeoutMs) || 3000));

  const found = await searchSsdp(timeoutMs);
  if (!found.ok) return found;

  const described = await fetchDescription(found.location);
  if (!described.ok) return described;

  const service = findWanService(described.body, found.location);
  if (!service) {
    return fail(
      'the device that answered is not offering a port-forwarding service ' +
      '(no WANIPConnection or WANPPPConnection)',
      { location: found.location, router: found.router });
  }

  return {
    ok: true,
    controlUrl: service.controlUrl,
    serviceType: service.serviceType,
    location: found.location,
    router: found.router,
    localAddress: await localAddressFor(found.router),
  };
}

function searchSsdp(timeoutMs) {
  return new Promise((resolve) => {
    let socket;
    try {
      socket = dgram.createSocket({ type: 'udp4', reuseAddr: true });
    } catch (err) {
      resolve(fail(`could not open a UDP socket: ${err.message}`));
      return;
    }

    let settled = false;
    let timer = null;

    const finish = (result) => {
      if (settled) return;
      settled = true;
      if (timer) clearTimeout(timer);
      try { socket.close(); } catch (err) { /* already closing */ }
      resolve(result);
    };

    socket.on('error', (err) => {
      finish(fail(`SSDP search failed: ${err.message}`));
    });

    socket.on('message', (buffer, rinfo) => {
      // Cheap sanity: an SSDP reply is a tiny HTTP-shaped blob. Anything
      // larger is not one, and reading it as text is pointless.
      if (buffer.length > 8192) return;
      const text = buffer.toString('utf8');
      if (!/^HTTP\/1\.[01] 200/i.test(text)) return;
      const match = /^location:[ \t]*(\S{1,2048})\s*$/im.exec(text);
      if (!match) return;
      finish({ ok: true, location: match[1], router: rinfo.address });
    });

    const message = Buffer.from([
      'M-SEARCH * HTTP/1.1',
      `HOST: ${SSDP_ADDRESS}:${SSDP_PORT}`,
      'MAN: "ssdp:discover"',
      'MX: 2',
      `ST: ${SSDP_TARGET}`,
      '', '',
    ].join('\r\n'), 'ascii');

    socket.bind(() => {
      const send = () => {
        if (settled) return;
        socket.send(message, 0, message.length, SSDP_PORT, SSDP_ADDRESS, (err) => {
          if (err && !settled) {
            finish(fail(
              `could not send the SSDP search: ${err.message}. Multicast does not ` +
              'leave every network -- a container without host networking, or a ' +
              'machine whose only route is a VPN, cannot reach a router this way. ' +
              'Forward the port by hand instead.'));
          }
        });
      };
      send();
      // UDP multicast on a busy home network drops packets often enough that
      // one probe is a coin flip; a second one costs nothing.
      const again = setTimeout(send, Math.min(600, Math.floor(timeoutMs / 3)));
      if (again.unref) again.unref();
    });

    timer = setTimeout(() => {
      finish(fail(
        `no UPnP router answered within ${timeoutMs} ms. Many routers ship with ` +
        'UPnP turned off, which is a reasonable default -- forward the port by ' +
        'hand instead.'));
    }, timeoutMs);
    if (timer.unref) timer.unref();
  });
}

function parseLocation(location) {
  try {
    const url = new URL(location);
    if (url.protocol !== 'http:') return null; // https device descriptions do not exist in practice
    return url;
  } catch (err) {
    return null;
  }
}

function fetchDescription(location) {
  return new Promise((resolve) => {
    const url = parseLocation(location);
    if (!url) {
      resolve(fail(`the router gave an address this cannot read: ${String(location).slice(0, 120)}`));
      return;
    }

    let settled = false;
    const finish = (result) => {
      if (settled) return;
      settled = true;
      resolve(result);
    };

    const request = http.get({
      host: url.hostname,
      port: url.port || 80,
      path: `${url.pathname}${url.search}`,
      timeout: HTTP_TIMEOUT_MS,
      headers: { Accept: 'text/xml', Connection: 'close' },
    }, (response) => {
      if (response.statusCode !== 200) {
        response.resume();
        finish(fail(`the router's description returned HTTP ${response.statusCode}`));
        return;
      }
      let body = '';
      let bytes = 0;
      response.setEncoding('utf8');
      response.on('data', (chunk) => {
        bytes += Buffer.byteLength(chunk, 'utf8');
        if (bytes > MAX_BODY_BYTES) {
          // Stop reading rather than grow without bound. Everything needed is
          // near the top of the document anyway.
          response.destroy();
          finish({ ok: true, body, base: url, truncated: true });
          return;
        }
        body += chunk;
      });
      response.on('end', () => finish({ ok: true, body, base: url, truncated: false }));
      response.on('error', (err) => finish(fail(`could not read the router's description: ${err.message}`)));
    });

    request.on('timeout', () => {
      request.destroy();
      finish(fail(`the router did not answer within ${HTTP_TIMEOUT_MS} ms`));
    });
    request.on('error', (err) => finish(fail(`could not reach the router: ${err.message}`)));
  });
}

/**
 * Walk the <service> blocks looking for one that forwards ports, and resolve
 * its controlURL against the description's own address. Split-then-match
 * rather than a single regex over the whole document, so a serviceType from
 * one service can never be paired with a controlURL from another.
 */
function findWanService(xml, location) {
  if (typeof xml !== 'string' || !xml) return null;
  const base = parseLocation(location);
  if (!base) return null;

  const urlBase = tagValue(xml, 'URLBase');
  const root = urlBase ? urlBase : base.href;

  const blocks = xml.split(/<service\b[^>]*>/i).slice(1);
  const candidates = [];
  for (const block of blocks) {
    const end = block.search(/<\/service>/i);
    const body = end >= 0 ? block.slice(0, end) : block.slice(0, 4096);
    const serviceType = tagValue(body, 'serviceType');
    const controlURL = tagValue(body, 'controlURL');
    if (!serviceType || !controlURL) continue;
    candidates.push({ serviceType, controlURL });
  }

  for (const wanted of WAN_SERVICES) {
    const hit = candidates.find((entry) => entry.serviceType.toLowerCase() === wanted.toLowerCase());
    if (!hit) continue;
    try {
      return { serviceType: hit.serviceType, controlUrl: new URL(hit.controlURL, root).href };
    } catch (err) {
      return null;
    }
  }
  return null;
}

// --------------------------------------------------------------------- SOAP

function soap(device, action, args) {
  return new Promise((resolve) => {
    const url = parseLocation(device.controlUrl);
    if (!url) {
      resolve(fail(`the router gave a control address this cannot read: ${String(device.controlUrl).slice(0, 120)}`));
      return;
    }

    const fields = Object.entries(args)
      .map(([name, value]) => `<${name}>${xmlEscape(value)}</${name}>`)
      .join('');
    const body =
      '<?xml version="1.0"?>' +
      '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" ' +
      's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>' +
      `<u:${action} xmlns:u="${device.serviceType}">${fields}</u:${action}>` +
      '</s:Body></s:Envelope>';

    let settled = false;
    const finish = (result) => {
      if (settled) return;
      settled = true;
      resolve(result);
    };

    const request = http.request({
      method: 'POST',
      host: url.hostname,
      port: url.port || 80,
      path: `${url.pathname}${url.search}`,
      timeout: HTTP_TIMEOUT_MS,
      headers: {
        'Content-Type': 'text/xml; charset="utf-8"',
        'Content-Length': Buffer.byteLength(body),
        SOAPAction: `"${device.serviceType}#${action}"`,
        Connection: 'close',
      },
    }, (response) => {
      let text = '';
      let bytes = 0;
      response.setEncoding('utf8');
      response.on('data', (chunk) => {
        bytes += Buffer.byteLength(chunk, 'utf8');
        if (bytes > MAX_BODY_BYTES) {
          response.destroy();
          return;
        }
        text += chunk;
      });
      response.on('end', () => {
        if (response.statusCode === 200) {
          finish({ ok: true, body: text });
          return;
        }
        const code = Number.parseInt(tagValue(text, 'errorCode') || '', 10);
        const described = ERRORS[code];
        finish(fail(
          described
            ? `${action} refused: ${described} (UPnP error ${code})`
            : `${action} refused with HTTP ${response.statusCode}` +
              (Number.isInteger(code) ? ` (UPnP error ${code})` : ''),
          { code: Number.isInteger(code) ? code : null }));
      });
      response.on('error', (err) => finish(fail(`${action} failed while reading the reply: ${err.message}`)));
    });

    request.on('timeout', () => {
      request.destroy();
      finish(fail(`${action}: the router did not answer within ${HTTP_TIMEOUT_MS} ms`));
    });
    request.on('error', (err) => finish(fail(`${action} failed: ${err.message}`)));
    request.end(body);
  });
}

async function device(options) {
  if (options && options.device && options.device.controlUrl) return options.device;
  return discover({ timeoutMs: options && options.timeoutMs });
}

// ------------------------------------------------------------------ actions

/**
 * Ask the router to forward `port` (TCP) to this machine.
 *
 * The lease is the safety net: if the hub is killed rather than shut down, the
 * mapping closes itself when the lease runs out instead of leaving a hole open
 * indefinitely. Routers that reject leases outright (UPnP error 725) get one
 * retry with a permanent mapping, reported as such -- a permanent mapping the
 * host knows about is better than a silent failure to forward, but they have
 * to be told it will outlive the process.
 */
async function addMapping(options = {}) {
  const port = clampPort(options.port);
  if (port === null) return fail(`${options.port} is not a port number`);

  const found = await device(options);
  if (!found.ok && !found.controlUrl) return found;

  const internal = options.internalAddress || found.localAddress ||
    await localAddressFor(found.router);
  if (!internal) {
    return fail('could not work out which of this machine\'s addresses to forward to');
  }

  const lease = clampLease(options.leaseSeconds === undefined ? 3600 : options.leaseSeconds);
  const description = String(options.description || 'RBY MMO hub').slice(0, DESCRIPTION_MAX);

  const args = {
    NewRemoteHost: '',
    NewExternalPort: String(port),
    NewProtocol: 'TCP',
    NewInternalPort: String(port),
    NewInternalClient: internal,
    NewEnabled: '1',
    NewPortMappingDescription: description,
    NewLeaseDuration: String(lease),
  };

  let result = await soap(found, 'AddPortMapping', args);
  let permanent = false;
  if (!result.ok && result.code === 725) {
    args.NewLeaseDuration = '0';
    permanent = true;
    result = await soap(found, 'AddPortMapping', args);
  }
  if (!result.ok) return Object.assign(result, { device: found });

  return {
    ok: true,
    port,
    internalAddress: internal,
    leaseSeconds: permanent ? 0 : lease,
    permanent,
    description,
    device: found,
  };
}

/** Remove the mapping this software made. Missing (error 714) counts as done. */
async function removeMapping(options = {}) {
  const port = clampPort(options.port);
  if (port === null) return fail(`${options.port} is not a port number`);

  const found = await device(options);
  if (!found.ok && !found.controlUrl) return found;

  const result = await soap(found, 'DeletePortMapping', {
    NewRemoteHost: '',
    NewExternalPort: String(port),
    NewProtocol: 'TCP',
  });

  if (!result.ok && result.code === 714) {
    return { ok: true, port, alreadyGone: true, device: found };
  }
  if (!result.ok) return Object.assign(result, { device: found });
  return { ok: true, port, alreadyGone: false, device: found };
}

/**
 * The address the router believes it has on the far side.
 *
 * This is how `doctor` can report a public address without contacting anyone
 * but the router -- which is the whole reason the reachability report is
 * allowed to mention an external address at all.
 */
async function externalIp(options = {}) {
  const found = await device(options);
  if (!found.ok && !found.controlUrl) return found;

  const result = await soap(found, 'GetExternalIPAddress', {});
  if (!result.ok) return Object.assign(result, { device: found });

  const address = tagValue(result.body, 'NewExternalIPAddress');
  if (!address) return fail('the router answered without an address', { device: found });
  // Some routers report 0.0.0.0 while the WAN link is down; that is a real
  // answer and saying so beats printing it as if it were usable.
  return { ok: true, address, up: address !== '0.0.0.0', device: found };
}

/** What the router currently has mapped for `port`, if anything. */
async function getMapping(options = {}) {
  const port = clampPort(options.port);
  if (port === null) return fail(`${options.port} is not a port number`);

  const found = await device(options);
  if (!found.ok && !found.controlUrl) return found;

  const result = await soap(found, 'GetSpecificPortMappingEntry', {
    NewRemoteHost: '',
    NewExternalPort: String(port),
    NewProtocol: 'TCP',
  });

  if (!result.ok && result.code === 714) {
    return { ok: true, port, mapped: false, device: found };
  }
  if (!result.ok) return Object.assign(result, { device: found });

  return {
    ok: true,
    port,
    mapped: true,
    internalAddress: tagValue(result.body, 'NewInternalClient'),
    internalPort: Number.parseInt(tagValue(result.body, 'NewInternalPort') || '', 10) || port,
    description: tagValue(result.body, 'NewPortMappingDescription'),
    leaseSeconds: Number.parseInt(tagValue(result.body, 'NewLeaseDuration') || '', 10) || 0,
    device: found,
  };
}

/*
 * The warning `upnp enable` prints before it does anything. It lives here,
 * next to the code it describes, so the two cannot drift apart -- a warning
 * that no longer matches what the software does is worse than none.
 */
const ENABLE_WARNING = [
  'Read this before enabling automatic port forwarding.',
  '',
  '  Most home routers accept these requests from ANY device on the network,',
  '  with no authentication at all. That is not a flaw in this software -- it',
  '  is how UPnP works on most consumer hardware. It means the same door that',
  '  lets this hub open a port also lets a smart plug, a games console or a',
  '  guest laptop open one, without asking you.',
  '',
  '  What this software will do:',
  '    - ask the router to forward one TCP port to this machine, and nothing else',
  '    - take the mapping on a lease, so it expires by itself if this process',
  '      is killed rather than shut down',
  '    - remove the mapping on clean shutdown, and on `rby-mmo-hub upnp disable`',
  '',
  '  What it will not do:',
  '    - open any other port, now or later',
  '    - contact anything except your own router',
  '',
  '  If you would rather not use UPnP, forward the port on the router by hand',
  '  and leave this off. The hub does not care which way the port got opened.',
];

module.exports = {
  SSDP_ADDRESS,
  SSDP_PORT,
  SSDP_TARGET,
  WAN_SERVICES,
  ENABLE_WARNING,
  discover,
  addMapping,
  removeMapping,
  externalIp,
  getMapping,
};
