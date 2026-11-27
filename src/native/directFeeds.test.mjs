import assert from 'node:assert/strict';
import test from 'node:test';
import {
  loadDirectCameras,
  needsServerResponse,
  routeDirectRequest,
} from './directFeeds.js';

function jsonFetch(map) {
  return async (url) => {
    const href = String(url);
    const hit = [...map.entries()].find(([needle]) => href.includes(needle));
    if (!hit)
      return new Response('no', {
        status: 404,
        headers: { 'content-type': 'text/plain' },
      });
    const body = hit[1];
    return new Response(JSON.stringify(body), {
      status: 200,
      headers: { 'content-type': 'application/json' },
    });
  };
}

test('keyless feeds are fetched upstream and keyed routes ask for an uplink', async () => {
  const calls = [];
  const fetchImpl = async (url) => {
    calls.push(String(url));
    if (String(url).includes('gp.php')) {
      return new Response('ISS\n1 25544U\n2 25544\n', {
        status: 200,
        headers: { 'content-type': 'text/plain' },
      });
    }
    if (String(url).includes('/v2/mil')) {
      return new Response(JSON.stringify({ ac: [{ hex: 'ae1234' }] }), {
        status: 200,
        headers: { 'content-type': 'application/json' },
      });
    }
    if (String(url).includes('/v2/lat/')) {
      return new Response(
        JSON.stringify({
          now: 1_700_000_000,
          ac: [{ hex: 'abc123', lat: 30.2, lon: -97.7, alt_baro: 1000 }],
        }),
        { status: 200, headers: { 'content-type': 'application/json' } },
      );
    }
    return new Response('no', { status: 404 });
  };
  const tle = await routeDirectRequest(
    '/api/celestrak/stations',
    {},
    fetchImpl,
  );
  assert.equal(tle.status, 200);
  assert.match(await tle.text(), /^1 /m);
  assert.match(calls[0], /celestrak\.org/);

  const mil = await routeDirectRequest('/api/military', {}, fetchImpl);
  assert.equal(mil.headers.get('x-feed-source'), 'adsb.lol');
  assert.equal((await mil.json()).ac[0].hex, 'ae1234');

  const flights = await routeDirectRequest(
    '/api/flights?lat=30.2&lon=-97.7',
    {},
    fetchImpl,
  );
  const body = await flights.json();
  assert.equal(body.states[0][0], 'abc123');
  assert.equal(flights.headers.get('x-flight-source'), 'adsb.lol');

  const voice = await routeDirectRequest('/api/realtime/token', {}, fetchImpl);
  assert.equal(voice.status, 503);
  assert.equal((await voice.json()).error, 'Needs server, set UPLINK');
  assert.equal(
    await routeDirectRequest('https://example.com/tile.png', {}, fetchImpl),
    null,
  );
  assert.equal((await needsServerResponse().json()).code, 'NEEDS_SERVER');
});

test('public camera catalogs become direct image sources', async () => {
  const sources = await loadDirectCameras(
    jsonFetch(
      new Map([
        [
          'traffic-cam.json',
          {
            features: [
              {
                id: '1',
                geometry: { coordinates: [151.2, -33.87] },
                properties: {
                  title: 'Harbour',
                  href: 'https://webcams.transport.nsw.gov.au/a.jpg',
                },
              },
              {
                id: '2',
                geometry: { coordinates: [0, 0] },
                properties: {
                  href: 'https://webcams.transport.nsw.gov.au/b.jpg',
                },
              },
            ],
          },
        ],
        [
          'JamCam',
          [
            {
              id: 'JamCams_9',
              commonName: 'Westminster',
              lat: 51.5,
              lon: -0.12,
              additionalProperties: [
                { key: 'available', value: 'true' },
                {
                  key: 'imageUrl',
                  value:
                    'https://s3-eu-west-1.amazonaws.com/jamcams.tfl.gov.uk/9.jpg',
                },
              ],
            },
          ],
        ],
        [
          'cctvStatusD04',
          {
            data: [
              {
                cctv: {
                  inService: 'true',
                  location: {
                    latitude: '37.8',
                    longitude: '-122.4',
                    locationName: 'Bay',
                  },
                  imageData: {
                    static: {
                      currentImageURL:
                        'https://cwwp2.dot.ca.gov/cameras/bay.jpg',
                    },
                  },
                },
              },
            ],
          },
        ],
      ]),
    ),
  );
  const ids = sources.map((source) => source.provider).sort();
  assert.deepEqual(ids, [
    'Caltrans',
    'Live Traffic NSW',
    'Transport for London',
  ]);
  assert.ok(
    sources.every((source) => source.directImageUrl.startsWith('https://')),
  );
});
