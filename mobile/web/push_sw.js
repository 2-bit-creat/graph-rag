// Push-only service worker.
//
// Deliberately NOT flutter_service_worker.js: Flutter regenerates that file on
// every `flutter build web`, so any handler added there is lost on the next
// build. Registering a second worker keeps push handling in a file we own.
// It caches nothing and claims no fetch events — Flutter's worker keeps sole
// responsibility for asset caching, and two workers racing over fetch is a
// well-known way to serve stale bundles.

self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', (event) => event.waitUntil(self.clients.claim()));

self.addEventListener('push', (event) => {
  let payload = {};
  try {
    payload = event.data ? event.data.json() : {};
  } catch (_) {
    // A push service can wake us with no body (or a non-JSON one). Showing a
    // generic notification beats showing nothing: on some platforms a push
    // event that displays no notification counts against the origin's budget.
    payload = {};
  }

  const title = payload.title || 'Daynode';
  const options = {
    body: payload.body || '',
    icon: 'icons/Icon-192.png',
    badge: 'icons/Icon-192.png',
    // Same tag replaces the previous notification instead of stacking a new one
    // each night.
    tag: payload.tag || 'daynode',
    data: { url: payload.url || '/' },
  };

  event.waitUntil(self.registration.showNotification(title, options));
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const target = (event.notification.data && event.notification.data.url) || '/';

  event.waitUntil(
    // Focus an already-open tab rather than opening a duplicate.
    self.clients
      .matchAll({ type: 'window', includeUncontrolled: true })
      .then((clientList) => {
        for (const client of clientList) {
          if ('focus' in client) return client.focus();
        }
        return self.clients.openWindow ? self.clients.openWindow(target) : null;
      })
  );
});
