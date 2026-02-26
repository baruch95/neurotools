const CACHE_NAME = 'offline-markdown-editor-v3'; // Versioned cache name
const urlsToCache = [
  './', // Alias for index.html
  './index.html',
  './marked.min.js'
];

// Install event: cache core assets
self.addEventListener('install', event => {
  event.waitUntil(
    caches.open(CACHE_NAME) // Use the versioned CACHE_NAME
      .then(cache => {
        console.log('Opened cache:', CACHE_NAME);
        return cache.addAll(urlsToCache);
      })
  );
});

// Activate event: clean up old caches
self.addEventListener('activate', event => {
  event.waitUntil(
    caches.keys().then(cacheNames => {
      return Promise.all(
        cacheNames.map(cacheName => {
          if (cacheName !== CACHE_NAME) {
            console.log('Deleting old cache:', cacheName);
            return caches.delete(cacheName);
          }
        })
      );
    })
  );
  // Ensure the new service worker takes control immediately
  return self.clients.claim();
});

// Fetch event: serve cached assets if available, otherwise fetch from network (cache-first)
self.addEventListener('fetch', event => {
  event.respondWith(
    caches.match(event.request) // Check current and all other caches
      .then(response => {
        // Cache hit - return response
        if (response) {
          return response;
        }

        // Not in cache - fetch from network
        return fetch(event.request).then(
          networkResponse => {
            // Check if we received a valid response
            if (!networkResponse || networkResponse.status !== 200 || networkResponse.type !== 'basic') {
              return networkResponse;
            }

            // IMPORTANT: Clone the response. A response is a stream
            // and because we want the browser to consume the response
            // as well as the cache consuming the response, we need
            // to clone it so we have two streams.
            const responseToCache = networkResponse.clone();

            caches.open(CACHE_NAME) // Use the versioned CACHE_NAME to store new items
              .then(cache => {
                cache.put(event.request, responseToCache);
              });

            return networkResponse;
          }
        ).catch(error => {
          // Optional: Handle fetch errors, e.g., for offline fallback page
          console.log('Fetch failed; returning offline page instead.', error);
          // Example: return caches.match('/offline.html'); 
          // For this app, if core assets are cached, it should mostly work.
          // If an uncached asset (e.g. an image linked in markdown) fails, it will just fail to load.
        });
      })
  );
});
